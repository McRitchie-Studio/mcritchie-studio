# frozen_string_literal: true

# Standalone test for bin/full-suite-check — the WRITE half of the full-suite gate
# (bin/dor-check is the READ half). It shells out to the script with the two lanes
# stubbed (FULL_SUITE_TEST_CMD / FULL_SUITE_RUBOCOP_CMD) so the orchestration is
# exercised without a real multi-minute `bin/rails test`. Run directly:
#   ruby -Itest test/lib/full_suite_check_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "../../bin/lib/full_suite_gate"
require_relative "../../bin/lib/ci_test_command"
require_relative "../../bin/lib/system_test_browser"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class FullSuiteCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/full-suite-check", __dir__)
  DOR = File.expand_path("../../bin/dor-check", __dir__)

  # THE CHILD CERT HAS NO DATABASE — say so, or it inherits ours. The child is spawned
  # against a THROWAWAY tmpdir repo, but it inherits this process's env, where a
  # worktree's `bin/rails test` has exported TEST_DATABASE_URL (.env.test.local) and is
  # itself holding an open connection to that DB (any test in the run that loads
  # test_helper opens one). The orphan guard's DB backstop then probes the URL it was
  # handed, finds a foreign backend — THE TEST RUNNER THAT SPAWNED IT — and correctly
  # REFUSES, reddening these tests whenever the suite runs as one process. Full write-up
  # in test/lib/fast_check_test.rb (NO_AMBIENT_DB), which is where it bit hardest.
  #
  # NOTE the precedence is NOT the bug: cert_orphan_guard.rb#test_db_url reads the ambient
  # TEST_DATABASE_URL BEFORE the root's .env.test.local, and it must — config/database.yml
  # renders `url: <%= ENV["TEST_DATABASE_URL"] %>` and dotenv never overwrites an
  # already-set var, so the ambient value is the DB the LANE will really open. A guard
  # that resolved the DB any other way would probe one database while the suite trashed
  # another. The bug was that this harness handed the child a URL that had nothing to do
  # with the root it was certifying.
  NO_AMBIENT_DB = { "TEST_DATABASE_URL" => nil, "CERT_GUARD_PSQL" => "/nonexistent/psql" }.freeze

  # THE one place a child env is built in this file — the agent-session scrub and the
  # ambient-database scrub, together, so no spawn site can pick up either leak. (This
  # file had THREE spawn helpers; the third was found only because the first two were
  # fixed and four tests stayed red.)
  def child_env(overrides = {})
    OutboundSeams.env(NO_AMBIENT_DB.merge(overrides))
  end

  def test_child_env_never_hands_the_child_our_database
    env = child_env("FULL_SUITE_ROOT" => "/tmp/whatever")

    assert env.key?("TEST_DATABASE_URL"), "the key must be PRESENT and nil — that is what UNSETS it"
    assert_nil env["TEST_DATABASE_URL"],
              "a child cert rooted at a throwaway repo must not inherit THIS suite's test DB"
    assert_nil env["CLAUDE_CODE_SESSION_ID"], "…and still no live agent session"
    assert_equal "/tmp/whatever", env["FULL_SUITE_ROOT"], "overrides still pass through"
  end

  def test_lane_status_grades_missing_stale_and_fresh_evidence
    checks = ["[full-suite@abc1234] tests green", "[rubocop@def5678] lint clean"]

    assert_equal :fresh, FullSuiteGate.lane_status(checks, "full-suite", "abc1234")
    assert_equal :stale, FullSuiteGate.lane_status(checks, "full-suite", "fffffff")
    assert_equal :missing, FullSuiteGate.lane_status(checks, "e2e", "abc1234")
  end

  # A temp git repo with one commit; yields its dir.
  # `subpath:` puts the repo somewhere specific under the temp dir — e.g.
  # ".worktrees/<slug>", which is what makes it read as an agent DESK (DeskGuard).
  def with_repo(subpath: nil)
    Dir.mktmpdir do |tmp|
      dir = subpath ? File.join(tmp, subpath) : tmp
      FileUtils.mkdir_p(dir)
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      File.write(File.join(dir, "app.rb"), "base\n")
      write_repo_shape(dir, subpath) if subpath
      # The harness writes its stub CLIs and their log INTO the repo dir, so without
      # this they read as untracked dirt to the dirty-tree guard (cert_tree_guard.rb)
      # — test tooling, not uncommitted work. Committed with the baseline, so the
      # fixture yields a genuinely CLEAN tree.
      # stub.log* also covers the TASK stub's read-back sentinel (stub.log.updated).
      File.write(File.join(dir, ".gitignore"), "stub.log*\n*-stub\n")
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m init")
      yield dir
    end
  end

  # Make the fixture REPO-SHAPED, because the desk guard does not read a file — it BOOTS THE
  # APP and reads back the database it actually connects to (bin/lib/desk_guard.rb). A desk
  # fixture needs the REPO's config/database.yml (one level up from <repo>/.worktrees/<slug>
  # — the SHARED name, ERB-stripped so no env var can rewrite what the resolution is compared
  # against) and a `bin/rails` to boot. The shim answers with DESK_DB_STUB, defaulting to the
  # SHARED name: the hazard this gate exists to refuse.
  #
  # DESK FIXTURES ONLY. A plain `with_repo` (no subpath) is not under .worktrees/, so the
  # guard returns before it would boot anything and the shape buys nothing — while a
  # `bin/rails` it does not need would quietly rewrite two OTHER fixtures: the turf-monster
  # one asserts CiTestCommand still REFUSES a repo with no ci.yml, and the studio-engine one
  # asserts a gem has "no bin/rails to purge one with". Both would keep passing for the
  # wrong reason, or stop passing at all.
  def write_repo_shape(dir, subpath)
    repo_root = File.expand_path("../..", dir)
    FileUtils.mkdir_p(File.join(repo_root, "config"))
    File.write(File.join(repo_root, "config", "database.yml"), <<~YAML)
      default: &default
        adapter: postgresql
      test:
        <<: *default
        database: studio_test
    YAML

    FileUtils.mkdir_p(File.join(dir, "bin"))
    shim = File.join(dir, "bin", "rails")
    File.write(shim, "#!/bin/sh\necho \"DESKDB=${DESK_DB_STUB:-studio_test}\"\n")
    File.chmod(0o755, shim)
  end

  # Run the runner in --print mode (no task board) with both lanes stubbed.
  # Returns [stdout, exitcode]. test:/rubocop: are shell commands ("true"/"false").
  # child_env: bin/full-suite-check resolves SessionIdentity, so an un-neutralized child
  # would read the LIVE agent session (test/support/session_env.rb) — and it would probe
  # our test DB (see NO_AMBIENT_DB). Both scrubs live in child_env.
  def run_check(dir, test_cmd:, rubocop_cmd:, reset_cmd: "true", extra_env: {}, merge_stderr: false)
    env = child_env(
      {
        "FULL_SUITE_ROOT" => dir,
        "FULL_SUITE_TEST_DB_RESET_CMD" => reset_cmd,
        "FULL_SUITE_TEST_CMD" => test_cmd,
        "FULL_SUITE_RUBOCOP_CMD" => rubocop_cmd
      }.merge(extra_env)
    )
    redirect = merge_stderr ? "2>&1" : "2>/dev/null"
    out = IO.popen(env, "#{BIN} --print #{redirect}", &:read)
    [out, $?.exitstatus]
  end

  # A repo fixture that IDENTIFIES as a given slug. cert_repo is resolved from the
  # checkout's origin remote (CertRootGuard.repo_of_checkout), so a waiver test
  # cannot be written without one — the temp repo would otherwise answer with its
  # random tmpdir name and no registry row would ever match.
  def with_repo_named(slug)
    with_repo do |dir|
      assert system("git -C #{dir} remote add origin " \
                    "https://github.com/McRitchie-Studio/#{slug}.git >/dev/null 2>&1"),
             "could not name the fixture repo #{slug}"
      yield dir
    end
  end

  # --- the declared lint waiver, EXECUTED ----------------------------------------
  #
  # These replace a guard that only grepped this script's source text. That guard
  # passed unchanged while the exit decision was mutated to ignore the rubocop lane
  # entirely — a cert that cannot fail, which is the one outcome the waiver must
  # never produce. Source-text assertions cannot see that; running the thing can.

  def test_a_waived_repo_omits_the_rubocop_lane_instead_of_running_it
    with_repo_named("studio-engine") do |dir|
      # rubocop_cmd is FALSE on purpose: if the waiver merely recorded a green
      # stamp without honouring it, or ran the lane anyway, this run goes red.
      out, code = run_check(dir, test_cmd: "true", rubocop_cmd: "false")

      assert_equal 0, code, "a waived repo with a green suite must certify:\n#{out}"
      assert_equal 1, out.scan(/\[full-suite@\h+:studio-engine\]/).length,
        "exactly one full-suite evidence line is owed:\n#{out}"
      refute_match(/\[rubocop@/, out,
        "a waived lane must be OMITTED, never stamped — a faked green is the defect " \
        "this whole task exists to avoid:\n#{out}")
    end
  end

  def test_a_waived_repo_with_a_red_suite_still_fails_and_records_nothing
    with_repo_named("studio-engine") do |dir|
      out, code = run_check(dir, test_cmd: "false", rubocop_cmd: "true")

      refute_equal 0, code, "waiving the LINT lane must not waive the SUITE:\n#{out}"
      refute_match(/\[full-suite@/, out, "a red suite records no evidence:\n#{out}")
      refute_match(/\[rubocop@/, out, "and certainly not a rubocop line:\n#{out}")
    end
  end

  # THE WAIVER IS DECLARED, NEVER INFERRED — asserted as a PROPERTY, not a spelling.
  # An earlier version of this guard grepped for the words a probe might be written
  # with, which any rephrasing defeats (`command -v rubocop` slipped straight past
  # it). This asks the only question that matters: a repo with NO waiver whose
  # rubocop cannot even be executed must FAIL CLOSED, not quietly skip the lane.
  def test_an_unwaived_repo_whose_rubocop_is_missing_fails_closed
    with_repo_named("turf-monster") do |dir|
      out, code = run_check(dir, test_cmd: "true",
                                 rubocop_cmd: File.join(dir, "definitely-not-installed"))

      refute_equal 0, code,
        "a missing rubocop must be a RED lane, never an inferred waiver — inferring one " \
        "turns every broken rubocop install into a silently skipped gate:\n#{out}"
      refute_match(/\[rubocop@/, out, "and it records no rubocop evidence:\n#{out}")
    end
  end

  # THE REPORTED DEFECT, EXECUTED END TO END. `bin/full-suite-check` could not pass
  # in solana-studio at all: the repo ships no rubocop (no .rubocop.yml, no
  # bin/rubocop, none in the Gemfile or gemspec), so the lint lane came back COULD
  # NOT RUN and the writer exits before recording — discarding the GREEN suite lane
  # with it. That mattered beyond cosmetics because pr-review-primary.md names this
  # command as THE escape when a PR's CI verdict is unreadable, so a reviewer there
  # had no path at all.
  #
  # NOTHING IS STUBBED THAT WOULD HIDE IT: no FULL_SUITE_TEST_CMD (the registry must
  # resolve bin/release-check) and no FULL_SUITE_RUBOCOP_CMD (the default bin/rubocop
  # is genuinely absent from the fixture, exactly as it is from the real repo). Drop
  # the `lint_lane: none` line from the registry and this test goes red on the same
  # COULD NOT RUN the bug report carries.
  def test_a_toolchain_less_gem_certifies_instead_of_a_false_red
    with_repo_named("solana-studio") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/release-check"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(dir, "bin/release-check"))

      out, code = run_check_unaided(dir, rubocop_cmd: nil)

      assert_equal 0, code, "a repo with no lint toolchain must still certify:\n#{out}"
      assert_match(/\[full-suite@\h+:solana-studio\]/, out,
        "the GREEN suite lane's evidence must survive — discarding it is the bug:\n#{out}")
      refute_match(/COULD NOT RUN/, out,
        "the lane must be SKIPPED as declared, never attempted and reported unrunnable:\n#{out}")
      refute_match(/\[rubocop@/, out,
        "and skipped means OMITTED — a stamp for a lint that never ran is the dishonest fix:\n#{out}")
    end
  end

  # --- the waiver AUDIT: absent must not outlive the fact -------------------------
  #
  # The waiver is a claim about the tree. Trusted forever, it lets a waived repo GAIN
  # rubocop and go on certifying green while nothing lints it — indistinguishable from
  # a repo that genuinely has none, which is the confusion the whole fix turns on. So
  # a declaration is refused the moment the tree contradicts it, and the refusal lands
  # BEFORE any lane: a stale registry line is not worth a multi-minute suite to find.

  def test_a_waived_repo_that_has_GAINED_rubocop_is_refused_not_silently_unlinted
    with_repo_named("solana-studio") do |dir|
      File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n  NewCops: enable\n")
      log = File.join(dir, "order.log")

      out, code = run_check(dir, test_cmd: append_command(log, "test"), rubocop_cmd: "true",
                                 merge_stderr: true)

      refute_equal 0, code, "a waiver whose claim has stopped being true must not certify:\n#{out}"
      assert_match(/\.rubocop\.yml/, out, "the refusal must name what it found:\n#{out}")
      assert_match(/config\/release_repos\.yml/, out,
        "and point at the DECLARATION as the repair, not at this run:\n#{out}")
      refute_match(/\[full-suite@/, out, "nothing may be certified:\n#{out}")
      refute File.exist?(log),
        "and it must refuse BEFORE any lane runs — discovering a stale registry line after a " \
        "full suite is the expensive version of being right"
    end
  end

  def test_an_unwaived_repo_is_never_refused_by_the_waiver_audit
    with_repo_named("turf-monster") do |dir|
      # The same tree shape that revokes a waiver above. Here there IS no waiver, so
      # the audit must stay silent: it revokes, it never grants, and it has no opinion
      # about a repo that declared nothing.
      File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n")
      out, code = run_check(dir, test_cmd: "true", rubocop_cmd: "true")

      assert_equal 0, code, "the audit must not touch a repo that declared no waiver:\n#{out}"
      assert_match(/\[rubocop@\h+:turf-monster\]/, out,
        "and that repo still owes — and records — its rubocop lane:\n#{out}")
    end
  end

  # The RED path's other half. A missing rubocop in an unwaived repo stays RED (see
  # test_an_unwaived_repo_whose_rubocop_is_missing_fails_closed — a missing binary
  # waives nothing, or every broken install becomes a silent skip), but "the COMMAND
  # is the problem" left a builder in a genuinely toolchain-less repo with no route.
  # The verdict is unchanged; the reader is told where the honest route is.
  def test_an_unrunnable_lint_lane_names_the_registry_route_without_taking_it
    with_repo_named("turf-monster") do |dir|
      out, code = run_check(dir, test_cmd: "true",
                                 rubocop_cmd: File.join(dir, "definitely-not-installed"),
                                 merge_stderr: true)

      refute_equal 0, code, "naming the route must not soften the verdict:\n#{out}"
      assert_match(/lint_lane: none/, out, "the builder is told the declaration exists:\n#{out}")
      assert_match(/config\/release_repos\.yml/, out, "and where it is written:\n#{out}")
      refute_match(/\[rubocop@/, out, "while nothing is certified for the lane:\n#{out}")
    end
  end

  # --- the registry-resolved TEST lane ------------------------------------------
  #
  # The lint waiver was only the THIRD of three ENOENT crash points. On a default
  # run a gem repo died earlier — at the test-db-reset lane and then the suite lane,
  # both `bin/rails`, which a gem does not have — so the waiver code was never even
  # reached. Acceptance said "a waived repo can produce a full cert"; until this
  # resolved, it could only do so with two hand-passed env overrides.

  def test_a_gem_repo_takes_its_test_command_from_the_registry
    with_repo_named("studio-engine") do |dir|
      log = File.join(dir, "order.log")
      # No FULL_SUITE_TEST_CMD: this is the UNAIDED path, which is the whole point.
      # reset_cmd would append "reset" if the lane ran; a gem has no test DB, so it
      # must not.
      # The registry names bin/release-check; the fixture must actually carry one.
      File.write(File.join(dir, "release-check-stub"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(dir, "release-check-stub"))
      Dir.mkdir(File.join(dir, "bin")) unless Dir.exist?(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/release-check"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(dir, "bin/release-check"))

      out, code = run_check_unaided(dir, reset_cmd: append_command(log, "reset"))

      assert_equal 0, code, "an unaided cert must complete for a gem repo:\n#{out}"
      refute File.exist?(log),
        "the Rails test-DB reset lane must not run for a gem — it has no test database " \
        "and no bin/rails to purge one with"
      assert_match(/\[full-suite@\h+:studio-engine\]/, out,
        "the suite lane still owes its evidence line:\n#{out}")
    end
  end

  def test_an_app_repo_still_resolves_its_test_command_from_ci
    with_repo_named("turf-monster") do |dir|
      out, code = run_check_unaided(dir)

      # turf-monster has no ci.yml in this fixture, so CiTestCommand must REFUSE.
      # What matters is that it is still ASKED — the registry path must not have
      # quietly become the answer for every repo.
      refute_equal 0, code, "an app repo with no ci.yml must still be refused:\n#{out}"
    end
  end

  # A lane command that does not exist used to raise an unrescued Errno::ENOENT
  # out of Process.spawn — mid-run, AFTER the g1_cert attempt had opened, which
  # nothing then closed. The builder got a backtrace instead of a verdict and the
  # board got a lane stuck open. It must be an ordinary red lane instead.
  def test_a_lane_command_that_cannot_launch_is_a_red_lane_not_a_crash
    with_repo_named("turf-monster") do |dir|
      missing = File.join(dir, "no-such-command")
      out, code = run_check(dir, test_cmd: missing, rubocop_cmd: "true", merge_stderr: true)

      refute_equal 0, code, "an unlaunchable lane must fail the cert:\n#{out}"
      refute_match(/Errno::ENOENT|cert_process\.rb:\d+:in/, out,
        "it must not surface as a Ruby backtrace — that is the crash this replaced:\n#{out}")
      assert_match(/COULD NOT RUN/, out,
        "and it must say the COMMAND is the problem, not the diff:\n#{out}")
      refute_match(/\[full-suite@/, out, "nothing may be certified:\n#{out}")
    end
  end

  # Like run_check, but WITHOUT FULL_SUITE_TEST_CMD — the path a builder actually
  # runs, and the one the acceptance criterion is written about.
  # `rubocop_cmd: nil` UNSETS the override so the script falls back to its real
  # default, `bin/rubocop` — the only way to test a waiver honestly, since a stubbed
  # "true" would certify a waived repo and an unwaived one identically.
  def run_check_unaided(dir, reset_cmd: "true", rubocop_cmd: "true")
    env = child_env(
      "FULL_SUITE_ROOT" => dir,
      "FULL_SUITE_TEST_DB_RESET_CMD" => reset_cmd,
      "FULL_SUITE_RUBOCOP_CMD" => rubocop_cmd
    )
    out = IO.popen(env, "#{BIN} --print 2>&1", &:read)
    [out, $?.exitstatus]
  end

  def append_command(path, line)
    script = "File.open(ARGV.fetch(0), 'a') { |file| file.puts(ARGV.fetch(1)) }"
    "#{RbConfig.ruby.shellescape} -e #{script.shellescape} #{path.shellescape} #{line.shellescape}"
  end

  def test_resets_test_database_before_certifying_lanes
    with_repo do |dir|
      log = File.join(dir, "order.log")
      out, code = run_check(
        dir,
        reset_cmd: append_command(log, "reset"),
        test_cmd: append_command(log, "test"),
        rubocop_cmd: append_command(log, "rubocop")
      )

      assert_equal 0, code, out
      assert_equal %w[reset test rubocop], File.readlines(log, chomp: true)
    end
  end

  def test_reset_failure_aborts_without_certifying_evidence
    with_repo do |dir|
      log = File.join(dir, "order.log")
      out, code = run_check(
        dir,
        reset_cmd: "false",
        test_cmd: append_command(log, "test"),
        rubocop_cmd: append_command(log, "rubocop")
      )

      assert_equal 1, code, out
      assert_equal "", out
      refute File.exist?(log), "test and rubocop lanes must not run after reset failure"
    end
  end

  def test_both_lanes_green_records_both_evidence_lines
    with_repo do |dir|
      out, code = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      assert_equal 0, code, out
      assert_match(/\[full-suite@[0-9a-f]{7,64}(?::[^\]\s]+)?\]/, out)
      assert_match(/\[rubocop@[0-9a-f]{7,64}(?::[^\]\s]+)?\]/, out)
      # Both lanes stamp the SAME fingerprint (the current code state).
      fps = out.scan(/@([0-9a-f]{7,64})[:\]]/).flatten.uniq
      assert_equal 1, fps.size, "both lanes should share one fingerprint: #{out}"
    end
  end

  def test_red_rubocop_lane_exits_nonzero_and_omits_its_evidence
    # A lint-red tree must NOT certify: rubocop line absent, exit 1.
    with_repo do |dir|
      out, code = run_check(dir, test_cmd: "true", rubocop_cmd: "false")
      assert_equal 1, code, out
      assert_match(/\[full-suite@/, out)
      refute_match(/\[rubocop@/, out)
    end
  end

  def test_red_test_lane_exits_nonzero_and_omits_its_evidence
    with_repo do |dir|
      out, code = run_check(dir, test_cmd: "false", rubocop_cmd: "true")
      assert_equal 1, code, out
      assert_match(/\[rubocop@/, out)
      refute_match(/\[full-suite@/, out)
    end
  end

  def test_a_timed_out_runner_is_named_as_hung_never_as_a_red_suite
    with_repo do |dir|
      out, code = run_check(
        dir,
        test_cmd: "sleep 30",
        rubocop_cmd: "true",
        extra_env: { "FULL_SUITE_LANE_TIMEOUT" => "1" },
        merge_stderr: true
      )

      assert_equal 1, code, out
      assert_match(/RUNNER HUNG/, out)
      assert_match(/NOT a test failure/, out)
      assert_match(/FULL_SUITE_LANE_TIMEOUT/, out)
      refute_match(/lane\(s\) RED/, out,
                   "a runner that produced no verdict must never be reported as red tests")
      refute_match(/\[full-suite@/, out, "a timed-out runner must never certify its test lane")
    end
  end

  def test_recorded_fingerprint_matches_dor_check_view
    # The two halves must agree on the fingerprint, or evidence would never validate.
    with_repo do |dir|
      out, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      runner_fp = out[/@([0-9a-f]{7,64})[:\]]/, 1]
      dor_fp = IO.popen(child_env("DOR_CHECK_DIFF_ROOT" => dir), "#{DOR} --suite-fingerprint 2>/dev/null", &:read).strip
      assert_equal dor_fp, runner_fp
    end
  end

  def test_fingerprint_stable_across_commit
    # Certify a dirty tree, commit the same change → identical fingerprint, so the
    # evidence stays valid in a fresh checkout at the committed HEAD.
    with_repo do |dir|
      File.write(File.join(dir, "app.rb"), "base\nchange\n")
      dirty, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      dirty_fp = dirty[/@([0-9a-f]{7,64})[:\]]/, 1]
      assert system("git -C #{dir} add -A >/dev/null 2>&1")
      assert system("git -C #{dir} commit -q -m change >/dev/null 2>&1")
      committed, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      committed_fp = committed[/@([0-9a-f]{7,64})[:\]]/, 1]
      assert_equal dirty_fp, committed_fp
    end
  end

  def test_fingerprint_stable_across_commit_for_a_new_file
    # The case `git stash create` silently broke: a change that ADDS a file must
    # fingerprint the same before and after it is committed, or the evidence
    # certified pre-commit reads STALE on the reviewer's post-commit checkout
    # (a false REFUSE for the overwhelmingly common add-a-file change). Fails
    # against the old stash-create fingerprint, passes against the temp-index one.
    with_repo do |dir|
      File.write(File.join(dir, "added.rb"), "brand new\n") # untracked, never add'd
      dirty, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      dirty_fp = dirty[/@([0-9a-f]{7,64})[:\]]/, 1]
      assert system("git -C #{dir} add -A >/dev/null 2>&1")
      assert system("git -C #{dir} commit -q -m add-file >/dev/null 2>&1")
      committed, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      committed_fp = committed[/@([0-9a-f]{7,64})[:\]]/, 1]
      assert_equal dirty_fp, committed_fp,
                   "adding a file must not change the fingerprint across the commit boundary"
    end
  end

  def test_fingerprint_changes_when_an_untracked_file_is_edited
    # Freshness must fire for untracked files too: certify with an untracked file
    # present, then edit it (still untracked) → the fingerprint must change so the
    # recorded evidence goes STALE. The old stash-create fingerprint ignored
    # untracked content, so this edit slipped past the staleness check.
    with_repo do |dir|
      File.write(File.join(dir, "scratch.rb"), "one\n") # untracked
      first, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      first_fp = first[/@([0-9a-f]{7,64})[:\]]/, 1]
      File.write(File.join(dir, "scratch.rb"), "two\n") # edit, still untracked
      second, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      second_fp = second[/@([0-9a-f]{7,64})[:\]]/, 1]
      refute_equal first_fp, second_fp,
                   "editing an untracked file must change the fingerprint (staleness fires)"
    end
  end

  def test_no_fingerprint_outside_a_repo_exits_nonzero
    Dir.mktmpdir do |dir| # not a git repo
      out, code = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      assert_equal 1, code, out
      refute_match(/\[full-suite@/, out) # nothing certified without a fingerprint
    end
  end

  # --- [integration] the test lane must run CI's FULL suite (base + SYSTEM) -----
  # THE BUG THIS CLOSES. The lane ran `bin/rails test`, which SKIPS test/system,
  # while CI runs `bin/rails db:test:prepare test test:system`. So the cert whose
  # whole selling point is CI-INDEPENDENCE tested strictly LESS than CI: a builder
  # could take this route, go green, and ship with ZERO system coverage. (It is not
  # theoretical — for rolio, whose CI bin/dor-check cannot even read, this is the
  # ONLY cert path.) The lane now runs what the repo's OWN ci.yml runs, verbatim.

  # A temp git repo carrying a ci.yml, whose `bin/rails` is a STUB that logs the
  # argv it was handed — so what the lane ACTUALLY invokes is observable without a
  # multi-minute Rails run. Yields [dir, rails_log].
  #
  # `ci_steps:` writes a MULTI-STEP `test` job (each string one `run:`), which is
  # what it takes to exercise the step-SELECTION bug: with only one step there is
  # nothing to select wrong.
  # `extra_jobs` writes ADDITIONAL jobs beside `test` — the grain the resolver used to
  # be blind to (it read exactly `jobs.test.steps`), and the grain turf-monster's real
  # ci.yml already uses.
  def with_ci_repo(ci_cmd: "bin/rails db:test:prepare test test:system", ci_steps: nil, extra_jobs: nil,
                   extra_yaml: nil)
    steps = ci_steps || (ci_cmd && [ci_cmd])
    with_repo do |dir|
      if steps
        FileUtils.mkdir_p(File.join(dir, ".github", "workflows"))
        runs = steps.map { |step| "      - name: Step\n        run: #{step}\n" }.join
        yaml = +"jobs:\n  test:\n    steps:\n#{runs}"
        extra_jobs&.each do |job, job_steps|
          yaml << "  #{job}:\n    steps:\n"
          job_steps.each { |step| yaml << "      - name: Step\n        run: #{step}\n" }
        end
        yaml << extra_yaml if extra_yaml
        File.write(File.join(dir, ".github", "workflows", "ci.yml"), yaml)
      end
      log = File.join(dir, "rails.log")
      FileUtils.mkdir_p(File.join(dir, "bin"))
      rails = File.join(dir, "bin", "rails")
      File.write(rails, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> #{log.shellescape}\n")
      FileUtils.chmod("+x", rails)
      yield dir, log
    end
  end

  # Run the cert with ONLY the test lane left at its default (reset + rubocop are
  # stubbed green), so the log records exactly what the test lane chose to run.
  # FULL_SUITE_TEST_CMD is explicitly UNSET (nil) so an exported override in the
  # parent shell cannot mask the default. The browser seam is forced PRESENT so the
  # verdict is identical on a Mac and on CI's Linux runner.
  def run_default_test_lane(dir, extra_env = {})
    # child_env, NOT bare SessionEnv.neutralized — this shells a full-suite-check that
    # runs its DB preflight, so it MUST inherit NO_AMBIENT_DB (TEST_DATABASE_URL=nil +
    # CERT_GUARD_PSQL disabled) exactly as run_check does. Without it, the child inherits
    # the AMBIENT test DB and refuses when that DB is held — which is deterministic inside
    # the release gate, whose own suite is running in mcritchie_studio_gate_test while this
    # child tries to prepare it. (Green in CI, red in the gate: the exact gate-host
    # divergence the pre-QA gate warns about.) The stub bin/rails never touches a real DB,
    # so scrubbing the ambient one changes nothing this test asserts — it only stops the
    # child from colliding with the suite that spawned it.
    env = child_env({
      "FULL_SUITE_ROOT" => dir,
      "FULL_SUITE_TEST_CMD" => nil,
      "FULL_SUITE_TEST_DB_RESET_CMD" => "true",
      "FULL_SUITE_RUBOCOP_CMD" => "true",
      SystemTestBrowser::ENV_OVERRIDE => "1"
    }.merge(extra_env))
    out = IO.popen(env, "#{BIN} --print 2>&1", &:read)
    [out, $?.exitstatus]
  end

  def test_test_lane_runs_the_repos_own_ci_command_verbatim
    with_ci_repo do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 0, code, out
      assert_equal ["db:test:prepare test test:system"], File.readlines(log, chomp: true),
                   "the cert's test lane must invoke CI's command VERBATIM (base + system tiers)"
      assert_match(/\[full-suite@/, out)
    end
  end

  # --- [integration] a SETUP step must never be mistaken for the test lane -------
  # THE REGRESSION, end to end. Selecting CI's command by "first step that mentions
  # bin/rails" made any SETUP step the full-suite lane: a `bin/rails db:test:prepare`
  # step parked ahead of the real one got RUN, exited 0, and stamped
  # `[full-suite@<fp>] … green` having executed ZERO tests — a cert that lies, and
  # no consumer parses the command text afterwards to catch it. The lane is now
  # selected by what a step DOES (bin/lib/ci_test_command.rb `runs_tests?`).

  def test_a_setup_step_parked_ahead_of_the_tests_cannot_hijack_the_lane
    with_ci_repo(ci_steps: ["bin/rails db:test:prepare", "bin/rails db:test:prepare test test:system"]) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 0, code, out
      assert_equal ["db:test:prepare test test:system"], File.readlines(log, chomp: true),
                   "the lane ran the SETUP step and certified green having run NO tests"
      assert_match(/\[full-suite@/, out)
    end
  end

  def test_a_test_job_that_runs_no_tests_is_refused_not_certified
    # No step in the job runs tests. That is not "green" — there is nothing to be
    # green ABOUT. Refuse loudly, run nothing, certify nothing.
    setup_only = ["bin/rails db:test:prepare", "bin/rails assets:precompile", "bin/rails tailwindcss:build"]
    with_ci_repo(ci_steps: setup_only) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 1, code, out
      assert_match(/NONE of them runs tests/, out)
      refute_match(/\[full-suite@/, out, "a job with no test step must certify NOTHING")
      refute_path_exists log, "the cert must not RUN a setup step it refused to accept as the test lane"
    end
  end

  # --- [integration] CI's suite split ACROSS STEPS is refused, not half-run -------
  # THE SECOND REGRESSION, end to end. The resolver used to `.find` the FIRST step
  # that runs tests and silently drop the rest — so the most ordinary CI refactor
  # there is (give the system tier its own step, so the log reads nicely) made the
  # lane run `bin/rails test` and stamp `[full-suite@<fp>] … green` with test/system
  # NEVER RUN. Green cert, zero system coverage: the exact bug this task exists to
  # kill, respelled. A one-command lane cannot stand in for a suite CI runs in two
  # commands, so it REFUSES — like the multi-line script already did.

  def test_ci_that_runs_its_tests_in_two_steps_is_refused_not_half_certified
    split = ["bin/rails test", "bin/rails db:test:prepare test:system"]
    with_ci_repo(ci_steps: split) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 1, code, out
      assert_match(/2 STEPS/, out, "the refusal must name how many test steps CI has")
      assert_match(/test:system/, out, "and NAME the step the lane would have dropped")
      refute_match(/\[full-suite@/, out, "a half-run suite must certify NOTHING")
      refute_path_exists log,
                         "the lane RAN CI's first test step — that is the green cert with no system tier, back again"
    end
  end

  # --- [integration] CI's suite split ACROSS JOBS is refused, not narrowly certified -
  # THE THIRD REGRESSION, end to end — the same lie one grain up. The resolver read
  # exactly `jobs.test.steps`, so the identical split that refuses across STEPS
  # resolved in TOTAL SILENCE across JOBS: `jobs.test` still holds one single-line
  # rails test step, every step-grain guard passes, and the lane runs `bin/rails test`
  # and stamps `[full-suite@<fp>] … green` with test/system NEVER RUN — in a job the
  # cert never even read. Not hypothetical: turf-monster runs a second test-bearing
  # job (playwright) TODAY.

  def test_ci_that_runs_its_tests_in_ANOTHER_JOB_is_refused_not_narrowly_certified
    with_ci_repo(ci_cmd: "bin/rails test",
                 extra_jobs: { "system_test" => ["bin/rails db:test:prepare test:system"] }) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 1, code, out
      assert_match(/MORE THAN ONE JOB/, out, "the refusal must say the suite is split across JOBS")
      assert_match(/system_test/, out, "and NAME the job the lane would have left unrun")
      assert_match(/test:system/, out, "and the step inside it")
      refute_match(/\[full-suite@/, out, "a suite split across jobs must certify NOTHING")
      refute_path_exists log,
                         "the lane RAN the narrower job's command — the green cert with no system tier, back again"
    end
  end

  # THE TWO ESCAPES PAST THE JOB-GRAIN GUARD, at the cert lane itself. Both resolved
  # GREEN against the previous round: the job-grain scan reused the NARROW structural
  # probe (which cannot see a WRAPPER), and the workflow reader SKIPPED any job with no
  # `steps:` (so a job-level `uses:` was invisible). Each ran `bin/rails test` and
  # stamped a green cert with the system tier NEVER RUN — the same lie, respelled.

  def test_a_WRAPPED_suite_in_ANOTHER_JOB_is_refused_not_narrowly_certified
    with_ci_repo(ci_cmd: "bin/rails test",
                 extra_jobs: { "system_test" => ["docker compose run web bin/rails db:test:prepare test:system"] }) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 1, code, out
      assert_match(/MORE THAN ONE JOB/, out, "a wrapped suite one job over is STILL a split suite")
      assert_match(/system_test/, out, "the refusal must NAME the job it would have left unrun")
      refute_match(/\[full-suite@/, out, "a suite the cert cannot see must certify NOTHING")
      refute_path_exists log, "the lane RAN the narrow half — the green cert with no system tier, back again"
    end
  end

  def test_a_JOB_THE_CERT_CANNOT_SEE_INTO_is_refused_not_certified_around
    # A job-level `uses:` has no `steps:`. Skipping it is not "not raising" — it is
    # PASSING, and a suite hiding in it certifies green, unread and unnamed.
    with_ci_repo(ci_cmd: "bin/rails test",
                 extra_yaml: "  system_test:\n    uses: ./.github/workflows/system.yml\n") do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 1, code, out
      assert_match(/CANNOT SEE INTO/, out)
      assert_match(/system_test/, out, "the refusal must NAME the job it could not read")
      refute_match(/\[full-suite@/, out)
      refute_path_exists log
    end
  end

  def test_a_foreign_runner_beside_the_rails_step_is_refused_not_silently_dropped
    # The set COUNT's blind spot, end to end: `runs_tests?` is a whitelist, and a
    # whitelist fails OPEN when COUNTING — playwright was invisible, so the lane ran
    # the rails step alone and stamped green with CI's other runner never invoked.
    with_ci_repo(ci_steps: ["bin/rails db:test:prepare test test:system", "npx playwright test"]) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 1, code, out
      assert_match(/ANOTHER RUNNER/, out)
      assert_match(/playwright/, out, "the refusal must NAME the runner it would have dropped")
      refute_match(/\[full-suite@/, out)
      refute_path_exists log
    end
  end

  def test_a_turf_style_PLAYWRIGHT_JOB_still_certifies
    # THE LIVE NO-REGRESSION PROOF, at the cert lane itself. turf-monster's real ci.yml
    # runs a second test-bearing job (sharded playwright) beside `test` — and its cert
    # lane WORKS today. The job-grain guard must not brick it: playwright is a tier
    # this lane never claimed (docs/topics/testing.md), not a split of CI's RUBY suite.
    # Its rails steps are SETUP and must not read as tests — note `bin/rails runner -e
    # test e2e/seed.rb`, where `test` is the VALUE of -e (the RAILS_ENV), not a task.
    #
    # A guard that refuses a WORKING lane is worse than the latent bug it closes.
    turf_playwright = ["npm ci",
                       "npx playwright install --with-deps chromium",
                       "bin/rails db:test:prepare && bin/rails runner -e test e2e/seed.rb",
                       "bin/rails tailwindcss:build",
                       "npm test -- --grep-invert @devnet --shard=1/3"]
    with_ci_repo(extra_jobs: { "playwright" => turf_playwright }) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 0, code, "turf-monster's playwright job must not brick its cert lane: #{out}"
      assert_equal ["db:test:prepare test test:system"], File.readlines(log, chomp: true),
                   "the lane must still run CI's `test` job command, verbatim"
      assert_match(/\[full-suite@/, out)
    end
  end

  def test_test_lane_runs_the_system_tier_even_with_no_ci_workflow
    # No ci.yml to read → the fallback default. It must still carry the system tier;
    # a fallback that quietly drops it would reopen the hole for any repo whose CI
    # config the resolver can't parse.
    with_ci_repo(ci_cmd: nil) do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 0, code, out
      assert_equal [CiTestCommand::DEFAULT.sub("bin/rails ", "")], File.readlines(log, chomp: true)
      assert_includes CiTestCommand::DEFAULT, "test:system"
    end
  end

  def test_a_repo_whose_ci_runs_a_narrower_command_is_taken_at_its_word
    # The rule is "run what CI runs" — not "always add test:system". A repo whose CI
    # genuinely runs a narrower command gets that command, so the cert never invents
    # coverage CI itself doesn't have (and never invents a lane that can't run).
    with_ci_repo(ci_cmd: "bin/rails db:test:prepare test") do |dir, log|
      out, code = run_default_test_lane(dir)

      assert_equal 0, code, out
      assert_equal ["db:test:prepare test"], File.readlines(log, chomp: true)
    end
  end

  def test_the_env_seam_still_overrides_the_resolved_command
    with_ci_repo do |dir, log|
      out, code = run_default_test_lane(dir, "FULL_SUITE_TEST_CMD" => "true")

      assert_equal 0, code, out
      refute File.exist?(log), "an explicit FULL_SUITE_TEST_CMD must win over the resolved CI command"
    end
  end

  # --- [unit] the system tier needs a browser: a missing one is ENV, not RED -----

  def test_a_browserless_host_aborts_as_ENV_before_any_lane_runs
    # THE MISATTRIBUTION GUARD (the cert-side twin of bin/release.rb's). Without
    # Chrome, Selenium fails INSIDE the suite — which reads as a RED SUITE and sends
    # the builder hunting a phantom bug in their own diff. It must abort UP FRONT,
    # in the ENV class, having run nothing.
    with_ci_repo do |dir, log|
      out, code = run_default_test_lane(dir, SystemTestBrowser::ENV_OVERRIDE => "0")

      assert_equal 1, code, out
      assert_includes out, "NO Chrome"
      assert_includes out, "NOT a regression in your diff"
      assert_includes out, "brew install --cask google-chrome"
      refute File.exist?(log), "no lane may run on a browserless host — the abort is up front"
      refute_match(/\[full-suite@/, out, "a browserless host must certify NOTHING")
    end
  end

  def test_the_browser_guard_leaves_a_non_system_command_alone
    # A repo/override whose command doesn't run test:system needs no browser — a
    # browserless host must still be able to certify it.
    with_ci_repo(ci_cmd: "bin/rails test test/integration") do |dir, log|
      out, code = run_default_test_lane(dir, SystemTestBrowser::ENV_OVERRIDE => "0")

      assert_equal 0, code, out
      assert_equal ["test test/integration"], File.readlines(log, chomp: true)
    end
  end

  # --- [integration] opt-in pre-push hook installer ----------------------------

  def test_install_hook_writes_an_executable_opt_in_pre_push_hook
    with_repo do |dir|
      out = IO.popen(child_env("FULL_SUITE_ROOT" => dir), "#{BIN} --install-hook 2>&1", &:read)
      assert_equal 0, $?.exitstatus, out
      hook = File.join(dir, ".git", "hooks", "pre-push")
      assert File.exist?(hook), "pre-push hook should be installed: #{out}"
      assert File.executable?(hook), "pre-push hook should be executable"
      assert_includes File.read(hook), "exec bin/full-suite-check --print"
      # Idempotent: re-running succeeds and leaves a single managed hook.
      out2 = IO.popen(child_env("FULL_SUITE_ROOT" => dir), "#{BIN} --install-hook 2>&1", &:read)
      assert_equal 0, $?.exitstatus, out2
      assert_equal 1, File.read(hook).scan("exec bin/full-suite-check --print").size
      # Uninstall removes the managed hook.
      IO.popen(child_env("FULL_SUITE_ROOT" => dir), "#{BIN} --uninstall-hook 2>&1", &:read)
      refute File.exist?(hook), "uninstall should remove the managed hook"
    end
  end

  def test_install_hook_refuses_to_clobber_a_foreign_pre_push_hook
    with_repo do |dir|
      hooks = File.join(dir, ".git", "hooks")
      FileUtils.mkdir_p(hooks)
      foreign = File.join(hooks, "pre-push")
      File.write(foreign, "#!/bin/sh\necho not-ours\n")
      out = IO.popen(child_env("FULL_SUITE_ROOT" => dir), "#{BIN} --install-hook 2>&1", &:read)
      assert_equal 1, $?.exitstatus, "should refuse to clobber a foreign hook: #{out}"
      assert_equal "#!/bin/sh\necho not-ours\n", File.read(foreign), "a foreign hook must be left untouched"
    end
  end

  # --- test-scope telemetry (A3) -----------------------------------------------
  # Each cert lane self-reports a kind=test_scope AgentAction through the SAME
  # bin/agent-activity `action` verb bin/release.rb's run_test_scope uses. We point
  # FULL_SUITE_AGENT_ACTIVITY at a STUB that logs its argv (no board POST) and FORCE
  # the session env so a shelled run never emits into THIS live session — it emits
  # into the fake session we set, or (when blank) not at all.

  # The session env is neutralized by SessionEnv (test/support/session_env.rb) so a
  # shelled run never inherits THIS live session; the caller opts a fake one in via
  # `session:` (blank ⇒ genuinely UNSET, not an exported "").

  # A stub agent-activity: appends its tab-joined argv to STUB_LOG, exits 0.
  def write_activity_stub(dir)
    stub = File.join(dir, "fake-agent-activity")
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(ARGV.join("\\t")) }
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # Run the cert with the emit seam pointed at `agent_activity` and the session env
  # forced to `session` ("" ⇒ no session). Returns [out, exitcode, emits] where
  # emits is an Array<Hash> of parsed emit flags (empty when nothing emitted).
  def run_check_with_telemetry(dir, agent_activity:, session:, test_cmd: "true", rubocop_cmd: "true", reset_cmd: "true")
    log = File.join(dir, "emit.log")
    env = child_env(
      {
        "FULL_SUITE_ROOT" => dir,
        "FULL_SUITE_TEST_DB_RESET_CMD" => reset_cmd,
        "FULL_SUITE_TEST_CMD" => test_cmd,
        "FULL_SUITE_RUBOCOP_CMD" => rubocop_cmd,
        "FULL_SUITE_AGENT_ACTIVITY" => agent_activity,
        "STUB_LOG" => log,
        # The fake session this run emits into — blank ⇒ UNSET (no session at all).
        "CLAUDE_CODE_SESSION_ID" => session
      }
    )
    out = IO.popen(env, "#{BIN} --print 2>/dev/null", &:read)
    code = $?.exitstatus
    emits = File.exist?(log) ? File.readlines(log, chomp: true).map { |line| parse_emit(line) } : []
    [out, code, emits]
  end

  # Parse a tab-joined `action …` argv into { "flag" => value } (drops the -- prefix).
  def parse_emit(line)
    parts = line.split("\t")
    parts.each_index.each_with_object({}) do |i, flags|
      flags[parts[i].sub(/\A--/, "")] = parts[i + 1] if parts[i].start_with?("--")
    end
  end

  def test_emits_a_tagged_test_scope_action_per_lane
    # [unit] each green lane self-reports kind=test_scope + event_slug + pass + duration_ms.
    with_repo do |dir|
      stub = write_activity_stub(dir)
      out, code, emits = run_check_with_telemetry(dir, agent_activity: stub, session: "fake-session-abc")
      assert_equal 0, code, out
      assert_equal %w[full_suite_db_reset full_suite_test full_suite_rubocop],
                   emits.map { |e| e["event-slug"] }, "one tagged emit per lane, in run order"
      emits.each do |e|
        assert_equal "test_scope", e["kind"]
        assert_equal "pass", e["result-slug"]
        assert_match(/\A\d+\z/, e["duration-ms"].to_s, "duration_ms is a millisecond integer")
        refute_nil e["summary"], "carries a human summary"
      end
    end
  end

  def test_telemetry_is_a_no_op_when_no_session_is_present
    # [unit] no live session ⇒ the session gate skips the shell-out entirely, so the
    # cert stays green and emits NOTHING (mirrors run_test_scope's session guard).
    with_repo do |dir|
      stub = write_activity_stub(dir)
      out, code, emits = run_check_with_telemetry(dir, agent_activity: stub, session: "")
      assert_equal 0, code, out
      assert_empty emits, "no session ⇒ no emit"
    end
  end

  def test_telemetry_never_breaks_a_cert_when_the_emit_seam_is_broken
    # [unit] a missing/broken agent-activity must be swallowed — the cert's own
    # lane result is the ONLY load-bearing outcome; telemetry never fails it.
    with_repo do |dir|
      out, code, = run_check_with_telemetry(
        dir, agent_activity: File.join(dir, "does-not-exist"), session: "fake-session-xyz"
      )
      assert_equal 0, code, "broken telemetry target must not fail a green cert: #{out}"
    end
  end

  def test_cert_run_self_reports_lanes_end_to_end_including_a_fail_verdict
    # [integration] a full cert run self-reports every lane it runs — a red rubocop
    # lane emits result_slug=fail (and still exits the cert non-zero), while the
    # lanes before it emit pass, all in run order.
    with_repo do |dir|
      stub = write_activity_stub(dir)
      out, code, emits = run_check_with_telemetry(dir, agent_activity: stub, session: "fake-session-def", rubocop_cmd: "false")
      assert_equal 1, code, "a red lane fails the cert: #{out}"
      by_slug = emits.to_h { |e| [e["event-slug"], e["result-slug"]] }
      assert_equal "pass", by_slug["full_suite_db_reset"]
      assert_equal "pass", by_slug["full_suite_test"]
      assert_equal "fail", by_slug["full_suite_rubocop"], "the red lane self-reports a fail verdict"
      assert_equal %w[full_suite_db_reset full_suite_test full_suite_rubocop],
                   emits.map { |e| e["event-slug"] }, "lanes self-report in run order"
    end
  end

  # --- [integration] task-root guard: the cert must root at the TASK's tree ------
  # Regression for the 2026-07-12 fail-GREEN: run from the hub primary (on main),
  # the cert rooted at the cwd's git toplevel and green-certified MAIN's tree for
  # an unrelated task. With a task slug and an IMPLICIT root (cwd, no
  # FULL_SUITE_ROOT), the cert must verify the root IS the task's tree — its
  # checked-out branch is the task's branch, or it is the task's
  # .worktrees/<worktree_slug> dir — and REFUSE otherwise (bin/lib/cert_root_guard.rb).

  GUARD_JSON = JSON.generate(
    "metadata" => { "devops" => {
      "branch" => "feat/task-x", "worktree_slug" => "task-x", "checks_run" => []
    } }
  )

  # A stub board/gate CLI: appends "<MARKER>\t<argv…>" to STUB_LOG; `show` prints
  # TASK_SHOW_JSON (serving both the guard's read and the read-back baseline).
  # Minimally STATEFUL, same shape as fast_check_test's TASK stub: an `update`
  # drops a sentinel and CAPTURES its --checks VALUES (to .written), and `show`
  # after an update serves TASK_SHOW_JSON_AFTER_UPDATE (else TASK_SHOW_JSON) with
  # the captured lines MERGED IN — so the read-back sees the evidence lines the
  # cert actually wrote (their runtime fingerprint no fixture can spell).
  # STUB_READBACK_DROP_WRITTEN=1 suppresses the merge (models a write that never
  # landed); an AFTER_UPDATE board with a line dropped models a lost pre-existing
  # line (the written evidence is still merged back, that line is not).
  def write_cli_stub(dir, name, marker)
    stub = File.join(dir, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      log = ENV.fetch("STUB_LOG")
      File.open(log, "a") { |f| f.puts(["#{marker}", *ARGV].join("\\t")) }
      sentinel = log + ".updated"
      written  = log + ".written"
      if ARGV.first == "update"
        File.write(sentinel, "1")
        vals = []
        i = 0
        while i < ARGV.length
          if ARGV[i] == "--checks" then vals << ARGV[i + 1].to_s; i += 2 else i += 1 end
        end
        File.open(written, "a") { |f| vals.each { |v| f.puts(v) } }
      end
      if ARGV.first == "show"
        after = ENV["TASK_SHOW_JSON_AFTER_UPDATE"].to_s
        base  = (!after.empty? && File.exist?(sentinel)) ? after : ENV["TASK_SHOW_JSON"].to_s
        unless base.empty?
          doc = JSON.parse(base)
          if File.exist?(sentinel) && File.exist?(written) && ENV["STUB_READBACK_DROP_WRITTEN"] != "1"
            dv = ((doc["metadata"] ||= {})["devops"] ||= {})
            checks = Array(dv["checks_run"])
            File.readlines(written, chomp: true).each { |w| checks << w unless checks.include?(w) }
            dv["checks_run"] = checks
          end
          puts JSON.generate(doc)
        end
      end
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # Run the cert with an IMPLICIT root — cwd = `dir`, no FULL_SUITE_ROOT — and the
  # board/gate CLIs stubbed via the FULL_SUITE_*_BIN seams. stderr merges into
  # stdout so the refusal message is assertable. Returns [out, exitcode, log_lines].
  def run_check_implicit_root(dir, args, extra_env: {})
    log = File.join(dir, "stub.log")
    env = child_env(
      {
        "FULL_SUITE_TEST_DB_RESET_CMD" => "true",
        "FULL_SUITE_TEST_CMD" => "true",
        "FULL_SUITE_RUBOCOP_CMD" => "true",
        "FULL_SUITE_TASK_BIN" => write_cli_stub(dir, "task-stub", "TASK"),
        "FULL_SUITE_GATE_BIN" => write_cli_stub(dir, "gate-stub", "GATE"),
        "TASK_SHOW_JSON" => GUARD_JSON,
        "STUB_LOG" => log
      }.merge(extra_env)
    )
    out = IO.popen(env, "#{BIN} #{args} 2>&1", chdir: dir, &:read)
    code = $?.exitstatus
    lines = File.exist?(log) ? File.readlines(log, chomp: true).map { |l| l.split("\t") } : []
    [out, code, lines]
  end

  # --- [integration] desk guard: a half-built desk may not purge the shared test DB ---
  # This gate's FIRST lane is `db:test:purge`. In a desk with no isolated test DB,
  # config/database.yml resolves RAILS_ENV=test to the SHARED base <app>_test — so that
  # purge lands on the database the primary checkout and the release gate workspaces are
  # using, mid-suite. Assert the desk owns its DB before destroying anything, the same
  # order the gate workspaces assert in. bin/lib/desk_guard.rb.
  def test_a_desk_with_no_isolated_test_db_is_refused_before_the_purge
    with_repo(subpath: ".worktrees/half-built") do |dir|
      # The fixture's bin/rails shim answers with the SHARED name: bringup never gave this
      # desk a database of its own, so the purge would land on everyone else's.
      out, code, lines = run_check_implicit_root(dir, "")

      assert_equal 1, code, "a desk with no isolated test DB must refuse, not purge: #{out}"
      assert_match(/no isolated test DB/, out)
      assert_match(/SHARED base test database/, out)
      refute(lines.any? { |l| l[0] == "GATE" }, "the refusal fires BEFORE any gate attempt opens")
    end
  end

  # THE INERT-PIN VECTOR, on the gate whose FIRST LANE IS `db:test:purge`. A desk that PINS
  # an isolated DB the app IGNORES (turf-monster, no `url:` key in its test block) resolves
  # to the SHARED database — and a presence-checking guard waves it through, straight into a
  # purge of the database every other desk and the release gate are mid-suite against.
  def test_a_desk_whose_pin_is_ignored_by_the_app_is_refused_before_the_purge
    with_repo(subpath: ".worktrees/inert-pin") do |dir|
      File.write(File.join(dir, ".env.test.local"),
                 "TEST_DATABASE_URL=postgresql://localhost/studio_test_inert_pin\n")
      out, code, lines = run_check_implicit_root(dir, "")

      assert_equal 1, code, "a pin the app ignores is not isolation — REFUSE before the purge: #{out}"
      assert_match(/SHARED test database/, out)
      assert_match(/IGNORES it/, out)
      refute(lines.any? { |l| l[0] == "GATE" }, "the refusal fires BEFORE any gate attempt opens")
    end
  end

  # The control: the same desk layout, resolving to its OWN database, must NOT be refused.
  # A gate that refuses a properly-provisioned desk brings every G1 cert to a halt.
  def test_a_whole_desk_is_not_refused_by_the_desk_guard
    with_repo(subpath: ".worktrees/whole-desk") do |dir|
      out, code, = run_check_implicit_root(dir, "",
                                           extra_env: { "DESK_DB_STUB" => "studio_test_whole_desk" })

      refute_match(/no isolated test DB/, out, "a whole desk must clear the guard: #{out}")
      refute_match(/SHARED test database/, out)
      assert_equal 0, code, out
    end
  end

  def test_wrong_root_cert_is_refused_before_any_lane_runs
    with_repo do |dir|
      # cwd = a tree on its default branch (main/master) — NOT task-x's tree.
      out, code, lines = run_check_implicit_root(dir, "task-x")
      assert_equal 1, code, "a wrong-root cert must refuse, not green-certify: #{out}"
      assert_match(/not task-x's tree/, out, "the refusal names the task")
      assert_match(%r{feat/task-x}, out, "the refusal names the expected branch")
      refute_match(/\[full-suite@/, out, "no evidence for a tree the task never touched")
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  def test_task_branch_checkout_certifies_without_a_root_override
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      out, code, lines = run_check_implicit_root(dir, "task-x")
      assert_equal 0, code, "the task's own tree certifies from cwd with no override: #{out}"
      assert_match(/\[full-suite@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
    end
  end

  # --- [integration] read-back: same property as bin/fast-check's recorder ---------
  # The two certs share the recorder discipline (CertEmission): "preserved" is
  # verified against the board after the write, and a write whose read-back lost
  # pre-existing checks lines fails loudly, naming them for re-record.
  def test_lost_preexisting_lines_after_the_write_fail_the_cert_loudly
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      with_tiers = JSON.generate(
        "metadata" => { "devops" => {
          "branch" => "feat/task-x", "worktree_slug" => "task-x",
          "checks_run" => ["[unit] bin/rails test test/models"]
        } }
      )
      after = JSON.generate("metadata" => { "devops" => { "checks_run" => [] } })
      out, code, = run_check_implicit_root(dir, "task-x",
                                           extra_env: { "TASK_SHOW_JSON" => with_tiers,
                                                        "TASK_SHOW_JSON_AFTER_UPDATE" => after })
      assert_equal 1, code, "a write whose read-back lost pre-existing checks lines must fail loudly: #{out}"
      assert_match(/MISSING/, out)
      assert_match(%r{\[unit\] bin/rails test test/models}, out, "the lost line is named for re-record")
      refute_match(/tier tags preserved/, out)
    end
  end

  # Round-3 regression (review block, 2026-07-20 — Carl): the cert used to resend
  # its SNAPSHOT of the author's lines alongside its evidence. That is an author
  # write, so the funnel replaces the author namespace with content read before a
  # multi-minute suite ran — clobbering any tier line the board gained meanwhile.
  # The cert sends ONLY the lines it owns; the funnel merges at write time.
  def test_recording_sends_only_evidence_never_the_author_snapshot
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      with_tiers = JSON.generate(
        "metadata" => { "devops" => {
          "branch" => "feat/task-x", "worktree_slug" => "task-x",
          "checks_run" => ["[unit] bin/rails test test/models", "[integration] flows"]
        } }
      )
      _, code, lines = run_check_implicit_root(dir, "task-x", extra_env: { "TASK_SHOW_JSON" => with_tiers })
      assert_equal 0, code
      update = lines.find { |l| l[0] == "TASK" && l[1] == "update" }
      refute_nil update
      sent = update.each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      assert(sent.all? { |l| l.match?(/\A\[(full-suite|rubocop)@/) },
             "the cert sends ONLY the lanes it owns — no author snapshot: #{sent.inspect}")
      refute_includes sent, "[unit] bin/rails test test/models"
    end
  end

  # Round-5 regression (review block, 2026-07-20 — light lane): the cert must
  # verify the lines it OWNS. If the fresh [full-suite@…]/[rubocop@…] evidence
  # does not land, the cert cannot tell "landed" from "vanished" — the
  # missing-signal-read-as-success shape this PR kills. A read-back missing the
  # evidence must exit NONZERO and say "re-run the cert".
  def test_evidence_lines_missing_from_the_read_back_fail_the_cert
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      with_tiers = JSON.generate(
        "metadata" => { "devops" => {
          "branch" => "feat/task-x", "worktree_slug" => "task-x",
          "checks_run" => ["[unit] bin/rails test test/models"]
        } }
      )
      out, code, lines = run_check_implicit_root(dir, "task-x",
                                                 extra_env: { "TASK_SHOW_JSON" => with_tiers,
                                                              "STUB_READBACK_DROP_WRITTEN" => "1" })
      assert_equal 1, code, "a read-back missing the fresh evidence lines must FAIL the cert: #{out}"
      assert_match(/MISSING/, out)
      assert_match(/re-run the cert: bin\/full-suite-check task-x/, out)
      refute_match(/read-back confirms/, out)
      close = lines.select { |l| l[0] == "GATE" && l[1] == "close" }.last
      refute_nil close
      assert_includes close, "--failed", "the durable gate must not read success when the command exits 1"
    end
  end

  # Round-2 regression (review block, 2026-07-20): on a PARTIAL loss the printed
  # recovery re-records the UNION — survivors AND lost. `--checks` replaces the
  # author namespace, so a lost-lines-only remedy would drop the survivors.
  def test_partial_loss_recovery_re_records_survivors_and_lost_alike
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      before = JSON.generate(
        "metadata" => { "devops" => {
          "branch" => "feat/task-x", "worktree_slug" => "task-x",
          "checks_run" => ["[unit] surviving unit line", "[integration] lost integration line"]
        } }
      )
      after = JSON.generate("metadata" => { "devops" => { "checks_run" => ["[unit] surviving unit line"] } })
      out, code, = run_check_implicit_root(dir, "task-x",
                                           extra_env: { "TASK_SHOW_JSON" => before,
                                                        "TASK_SHOW_JSON_AFTER_UPDATE" => after })
      assert_equal 1, code, out
      remedy = out.lines.find { |l| l.include?("bin/task update task-x") }
      refute_nil remedy, "the loud failure prints a runnable re-record command: #{out}"
      # Assert the PROPERTY (what a shell parses out), not the quoting spelling.
      recorded = Shellwords.split(remedy[/bin\/task update task-x.*/].strip)
                           .each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      assert_includes recorded, "[integration] lost integration line", "the lost line is re-recorded"
      assert_includes recorded, "[unit] surviving unit line",
                      "the SURVIVING line must be in the remedy too — a lost-lines-only remedy drops survivors"
    end
  end

  # Round-3 regression (review block, 2026-07-20 — Shannon): the remedy is PASTED
  # into a shell, so it must be SHELL-quoted. String#inspect is a Ruby literal and
  # leaves $(…)/backticks live inside double quotes. Proven with a REAL shell.
  def test_recovery_command_is_shell_safe_not_ruby_inspect
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      pwned = File.join(dir, "pwned")
      nasty = %([integration] cost $(touch #{pwned}) and `touch #{pwned}` "quoted")
      before = JSON.generate(
        "metadata" => { "devops" => {
          "branch" => "feat/task-x", "worktree_slug" => "task-x", "checks_run" => [nasty]
        } }
      )
      after = JSON.generate("metadata" => { "devops" => { "checks_run" => [] } })
      out, code, = run_check_implicit_root(dir, "task-x",
                                           extra_env: { "TASK_SHOW_JSON" => before,
                                                        "TASK_SHOW_JSON_AFTER_UPDATE" => after })
      assert_equal 1, code, out
      remedy = out.lines.find { |l| l.include?("bin/task update task-x") }
      refute_nil remedy, out
      command = remedy[/bin\/task update task-x.*/].strip

      argv_log = File.join(dir, "remedy-argv.log")
      bindir = File.join(dir, "remedy-bin")
      FileUtils.mkdir_p(bindir)
      File.write(File.join(bindir, "task"), <<~SH)
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a" >> #{argv_log.shellescape}; done
      SH
      FileUtils.chmod("+x", File.join(bindir, "task"))
      system({ "PATH" => "#{bindir}:#{ENV.fetch('PATH')}" },
             "/bin/sh", "-c", command.sub(%r{\Abin/task}, "task"),
             out: File::NULL, err: File::NULL)

      refute File.exist?(pwned), "the remedy EXECUTED embedded shell syntax when pasted: #{command}"
      received = File.exist?(argv_log) ? File.readlines(argv_log, chomp: true) : []
      assert_equal nasty, received.last, "the shell must hand bin/task the line VERBATIM: #{received.inspect}"
    end
  end


  # --- [integration] a SIBLING's failure must not discard a lane that PASSED ----------
  #
  # THE BUG (measured 2026-09-01, /tasks/timeout-discards-passing-lane). The
  # all-or-nothing guard `exit 1`'d ABOVE the recording block, so a run whose suite
  # lane hung at the 2700s ceiling while rubocop went green over 1,229 files PRINTED
  # "[rubocop@<fp>:mcritchie-studio] bin/rubocop clean" and then recorded NOTHING.
  # Twenty minutes of valid, fingerprint-bound measurement was discarded because a
  # DIFFERENT lane produced no verdict, and bin/dor-check still read "rubocop:
  # MISSING". The retry re-paid those twenty minutes at an UNCHANGED tree hash.
  #
  # BOTH HALVES ARE THE TEST, and either alone proves nothing: banking without still
  # refusing would loosen the gate (the one outcome a cert must never produce), and
  # refusing without banking is the bug itself. So each of these asserts that the
  # green lane reaches the BOARD, that the lane which produced no verdict banks
  # NOTHING, that the exit stays 1, and that the durable G1 attempt still closes
  # --failed.
  def test_a_timed_out_lane_does_not_discard_a_sibling_that_passed
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      out, code, lines = run_check_implicit_root(
        dir, "task-x",
        extra_env: { "FULL_SUITE_TEST_CMD" => "sleep 30", "FULL_SUITE_LANE_TIMEOUT" => "1" }
      )

      # HALF ONE — the run still REFUSES. `ok` is unchanged and the task still owes
      # its suite lane; a banked sibling may never buy a pass.
      assert_equal 1, code, "a hung lane must still FAIL the cert — banking a sibling is not a pass:\n#{out}"
      assert_match(/RUNNER HUNG/, out, "the hung lane is still named HUNG, never reported as a red suite")
      close = lines.select { |l| l[0] == "GATE" && l[1] == "close" }.last
      refute_nil close, "the G1 attempt must still be closed:\n#{out}"
      assert_includes close, "--failed", "a banked sibling must never close the durable gate --success"

      # HALF TWO — the lane that COMPLETED GREEN is written to the board.
      sent = checks_sent(lines)
      assert(sent.any? { |l| l.match?(/\A\[rubocop@\h{7,64}(?::[^\]\s]+)?\] /) },
             "the lane that completed GREEN must be BANKED, not discarded by its sibling: #{sent.inspect}")
      refute(sent.any? { |l| l.match?(/\A\[full-suite@/) },
             "the lane that HUNG produced no verdict and must bank NOTHING: #{sent.inspect}")
      # Fingerprint-bound and repo-scoped, exactly as a green run's line is: the
      # banked evidence asserts what was measured AT THIS TREE, or it asserts nothing.
      assert_equal FullSuiteGate.fingerprint(dir), sent.first[/@(\h{7,64})[:\]]/, 1],
                   "banked evidence must carry the tree hash dor-check recomputes: #{sent.inspect}"
    end
  end

  # The same property with the sibling RED rather than HUNG — the two verdicts take
  # different arms of the guard, and a fix that only reached the timeout arm would
  # leave the commoner case still discarding good work.
  def test_a_red_lane_does_not_discard_a_sibling_that_passed
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      out, code, lines = run_check_implicit_root(dir, "task-x", extra_env: { "FULL_SUITE_TEST_CMD" => "false" })

      assert_equal 1, code, "a red lane must still FAIL the cert:\n#{out}"
      assert_match(/lane\(s\) RED/, out)
      close = lines.select { |l| l[0] == "GATE" && l[1] == "close" }.last
      assert_includes close.to_a, "--failed", "a banked sibling must never close the durable gate --success"

      sent = checks_sent(lines)
      assert(sent.any? { |l| l.match?(/\A\[rubocop@\h{7,64}(?::[^\]\s]+)?\] /) },
             "the GREEN lint lane must be banked even beside a red suite: #{sent.inspect}")
      refute(sent.any? { |l| l.match?(/\A\[full-suite@/) },
             "a RED lane must never record evidence: #{sent.inspect}")
    end
  end

  # A --print run is a DRY RUN: it prints the evidence and touches no board. The
  # partial bank must honour that seam exactly as the green path does, or `--print`
  # silently becomes a write. Run WITH a slug on purpose — a slugless run is refused
  # by a different guard, so passing one is the only way to exercise this seam.
  def test_print_mode_banks_nothing_when_a_sibling_hangs
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      out, code, lines = run_check_implicit_root(
        dir, "--print task-x",
        extra_env: { "FULL_SUITE_TEST_CMD" => "sleep 30", "FULL_SUITE_LANE_TIMEOUT" => "1" }
      )

      assert_equal 1, code, out
      assert_match(/\[rubocop@/, out, "--print still PRINTS the green lane's evidence")
      assert_empty checks_sent(lines), "--print must never write to the board: #{out}"
      refute_match(/banked on/, out, "…nor claim it did: #{out}")
    end
  end

  # The bank is VERIFIED, never declared — the same rule the green path holds itself
  # to (test_evidence_lines_missing_from_the_read_back_fail_the_cert is its twin).
  # A write that returns 200 but does not land must NOT be reported as banked, or a
  # builder re-runs believing a lane is already on the board.
  def test_a_bank_that_does_not_land_is_never_reported_as_banked
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      out, code, = run_check_implicit_root(
        dir, "task-x",
        extra_env: { "FULL_SUITE_TEST_CMD" => "sleep 30", "FULL_SUITE_LANE_TIMEOUT" => "1",
                     "STUB_READBACK_DROP_WRITTEN" => "1" }
      )

      assert_equal 1, code, out
      assert_match(/did NOT land/, out, "an unlanded bank must say so: #{out}")
      refute_match(/read-back confirms/, out, "…and must never claim confirmation: #{out}")
    end
  end

  # Every --checks VALUE the cert handed the board stub, across all update calls.
  def checks_sent(lines)
    lines.select { |l| l[0] == "TASK" && l[1] == "update" }
         .flat_map { |l| l.each_cons(2).select { |a, _| a == "--checks" }.map(&:last) }
  end

  # --- [integration] the orphan guard is wired into THIS cert too ---------------------
  #
  # This lane is the more exposed of the two: a multi-minute full suite (it will outrun
  # any agent-harness timeout) whose reset lane LEADS with `db:test:purge` — a DROP
  # DATABASE that Postgres refuses outright while an orphan holds a connection
  # (PG::ObjectInUse). The policy and its decision table are tested in
  # test/lib/cert_orphan_guard_test.rb and exercised end-to-end in
  # test/lib/fast_check_test.rb; here we prove the WIRING: this cert consults the guard
  # before any lane, and a refusal stops it dead.

  def test_a_live_concurrent_cert_is_refused_before_any_lane_runs
    with_repo do |dir|
      # A runlock whose cert process is still ALIVE: a real concurrent cert in this
      # tree. Running beside it puts two suites on one worktree test DB — they corrupt
      # each other's fixtures and SIGSEGV Ruby. Refuse; never kill a live sibling.
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      sibling = Process.spawn("sleep 60", pgroup: true)
      # The GIT DIR, not the tree: a runlock in the working tree is untracked dirt, and
      # the cert refuses a dirty tree. Asked of git directly, not of the code under test.
      git_dir = `git -C #{dir.shellescape} rev-parse --absolute-git-dir 2>/dev/null`.strip
      refute_empty git_dir, "the fixture repo must be a git repo"
      lock = File.join(git_dir, "cert-run.json")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, JSON.generate("cert_pid" => sibling, "pgid" => Process.getpgid(sibling),
                                     "lane" => "full-suite", "started_at" => "2026-07-13T05:00:00Z"))

      out, code, lines = run_check_implicit_root(dir, "task-x")

      assert_equal 1, code, "a concurrent cert in the same tree must be refused: #{out}"
      assert_match(/#{sibling}/, out, "the refusal names the running cert")
      assert_match(/NOT a regression in your diff/, out, "an ENV-class refusal must say so")
      refute_match(/\[full-suite@/, out, "nothing is certified against a contended test DB")
      refute(lines.any? { |l| l[0] == "GATE" }, "refusal fires BEFORE the G1 attempt opens: #{lines.inspect}")
    ensure
      begin
        if sibling
          Process.kill("KILL", sibling)
          Process.waitpid(sibling)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  # --- [integration] dirty-tree guard: certify only a fully-committed HEAD ----------
  # The cert fingerprint is a git TREE hash of the WORKING tree, so a cert taken with
  # edits uncommitted stamps GREEN evidence for code the PR never receives — live on
  # 2026-07-14, when a worktree's 146 lines of finished, tested work were certified
  # and then never reached PR #537. The refusal must land BEFORE any lane runs or any
  # gate/checkpoint/evidence write, exactly like the root guard above
  # (bin/lib/cert_tree_guard.rb).

  def test_dirty_tree_cert_is_refused_before_any_lane_runs
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # The RIGHT tree (task-x's branch) — but with an edit still uncommitted.
      File.write(File.join(dir, "app.rb"), "uncommitted work the PR will never see\n")

      out, code, lines = run_check_implicit_root(dir, "task-x")

      assert_equal 1, code, "an uncommitted tree must refuse, not green-certify: #{out}"
      assert_match(/DIRTY/, out)
      assert_match(/app\.rb/, out, "the refusal NAMES the uncommitted file")
      assert_match(/commit/i, out, "the refusal states the fix")
      refute_match(/\[full-suite@/, out, "no evidence for a tree that is not on the PR")
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  def test_untracked_file_refuses_the_cert
    # The fingerprint stages untracked-not-ignored files too (git add -A), so a brand
    # new, never-added file is exactly as invisible to the PR as an unstaged edit —
    # and it is what "146 lines of finished work" actually looked like.
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "brand_new.rb"), "class BrandNew; end\n")

      out, code, = run_check_implicit_root(dir, "task-x")
      assert_equal 1, code, "an untracked file is uncommitted work: #{out}"
      assert_match(/brand_new\.rb/, out)
    end
  end

  def test_stale_mtime_tree_still_certifies
    # THE FALSE POSITIVE the guard must not become. A tracked file rewritten with
    # IDENTICAL content has a fresh mtime, leaving git's stat cache stale — which the
    # cheap dirty reads (git diff-index) call MODIFIED. On the CERT path a false
    # refusal blocks every handoff, so the guard refreshes the index before reading
    # it. Unit-level proof, including the index-refresh mechanism itself, lives in
    # test/lib/cert_tree_guard_test.rb.
    with_repo do |dir|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      tracked = File.join(dir, "app.rb")
      body = File.read(tracked)
      File.write(tracked, body)                                       # byte-identical rewrite
      FileUtils.touch(tracked, mtime: Time.now + (10 * 365 * 24 * 3600))
      refute system("git", "-C", dir, "diff-index", "--quiet", "HEAD", out: File::NULL, err: File::NULL),
             "fixture check: the index must actually BE stat-stale, else this proves nothing"

      out, code, lines = run_check_implicit_root(dir, "task-x")

      assert_equal 0, code, "a stat-stale index is a CLEAN tree — it must still certify: #{out}"
      refute_match(/DIRTY/, out, "a file nobody edited must never be reported as uncommitted work")
      assert_match(/\[full-suite@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
    end
  end
end
