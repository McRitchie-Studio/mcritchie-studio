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
    SessionEnv.neutralized(NO_AMBIENT_DB.merge(overrides))
  end

  def test_child_env_never_hands_the_child_our_database
    env = child_env("FULL_SUITE_ROOT" => "/tmp/whatever")

    assert env.key?("TEST_DATABASE_URL"), "the key must be PRESENT and nil — that is what UNSETS it"
    assert_nil env["TEST_DATABASE_URL"],
              "a child cert rooted at a throwaway repo must not inherit THIS suite's test DB"
    assert_nil env["CLAUDE_CODE_SESSION_ID"], "…and still no live agent session"
    assert_equal "/tmp/whatever", env["FULL_SUITE_ROOT"], "overrides still pass through"
  end

  # --- [unit] merge_evidence: the writer must PRESERVE tier tags ---------------
  # bin/task update --checks REPLACES the whole list, so the runner merges. This
  # pure function is the merge: keep tier tags + bypass, replace prior evidence.

  def test_merge_evidence_preserves_tier_tags_and_replaces_prior_evidence
    existing = [
      "[unit] bin/rails test test/foo_test.rb",
      "[integration] request->db",
      "[full-suite@oldfp] stale tests",
      "[rubocop@oldfp] stale lint",
      "[full-suite-bypass] tracked elsewhere"
    ]
    fresh = ["[full-suite@newfp] tests green", "[rubocop@newfp] lint clean"]
    merged = FullSuiteGate.merge_evidence(existing, fresh)

    assert_includes merged, "[unit] bin/rails test test/foo_test.rb"
    assert_includes merged, "[integration] request->db"
    assert_includes merged, "[full-suite-bypass] tracked elsewhere"
    assert_includes merged, "[full-suite@newfp] tests green"
    assert_includes merged, "[rubocop@newfp] lint clean"
    refute_includes merged, "[full-suite@oldfp] stale tests"
    refute_includes merged, "[rubocop@oldfp] stale lint"
  end

  def test_merge_evidence_handles_empty_existing
    merged = FullSuiteGate.merge_evidence([], ["[full-suite@fp] x", "[rubocop@fp] y"])
    assert_equal ["[full-suite@fp] x", "[rubocop@fp] y"], merged
  end

  def test_lane_status_grades_missing_stale_and_fresh_evidence
    checks = ["[full-suite@abc1234] tests green", "[rubocop@def5678] lint clean"]

    assert_equal :fresh, FullSuiteGate.lane_status(checks, "full-suite", "abc1234")
    assert_equal :stale, FullSuiteGate.lane_status(checks, "full-suite", "fffffff")
    assert_equal :missing, FullSuiteGate.lane_status(checks, "e2e", "abc1234")
  end

  # A temp git repo with one commit; yields its dir.
  def with_repo
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      File.write(File.join(dir, "app.rb"), "base\n")
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

  # Run the runner in --print mode (no task board) with both lanes stubbed.
  # Returns [stdout, exitcode]. test:/rubocop: are shell commands ("true"/"false").
  # child_env: bin/full-suite-check resolves SessionIdentity, so an un-neutralized child
  # would read the LIVE agent session (test/support/session_env.rb) — and it would probe
  # our test DB (see NO_AMBIENT_DB). Both scrubs live in child_env.
  def run_check(dir, test_cmd:, rubocop_cmd:, reset_cmd: "true")
    env = child_env(
      {
        "FULL_SUITE_ROOT" => dir,
        "FULL_SUITE_TEST_DB_RESET_CMD" => reset_cmd,
        "FULL_SUITE_TEST_CMD" => test_cmd,
        "FULL_SUITE_RUBOCOP_CMD" => rubocop_cmd
      }
    )
    out = IO.popen(env, "#{BIN} --print 2>/dev/null", &:read)
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
      assert_match(/\[full-suite@[0-9a-f]{7,64}\]/, out)
      assert_match(/\[rubocop@[0-9a-f]{7,64}\]/, out)
      # Both lanes stamp the SAME fingerprint (the current code state).
      fps = out.scan(/@([0-9a-f]{7,64})\]/).flatten.uniq
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

  def test_recorded_fingerprint_matches_dor_check_view
    # The two halves must agree on the fingerprint, or evidence would never validate.
    with_repo do |dir|
      out, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      runner_fp = out[/@([0-9a-f]{7,64})\]/, 1]
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
      dirty_fp = dirty[/@([0-9a-f]{7,64})\]/, 1]
      assert system("git -C #{dir} add -A >/dev/null 2>&1")
      assert system("git -C #{dir} commit -q -m change >/dev/null 2>&1")
      committed, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      committed_fp = committed[/@([0-9a-f]{7,64})\]/, 1]
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
      dirty_fp = dirty[/@([0-9a-f]{7,64})\]/, 1]
      assert system("git -C #{dir} add -A >/dev/null 2>&1")
      assert system("git -C #{dir} commit -q -m add-file >/dev/null 2>&1")
      committed, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      committed_fp = committed[/@([0-9a-f]{7,64})\]/, 1]
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
      first_fp = first[/@([0-9a-f]{7,64})\]/, 1]
      File.write(File.join(dir, "scratch.rb"), "two\n") # edit, still untracked
      second, = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      second_fp = second[/@([0-9a-f]{7,64})\]/, 1]
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
  # TASK_SHOW_JSON (serving both the guard's read and the read-merge-write), exits 0.
  # Minimally STATEFUL for the read-back verification: an `update` drops a sentinel
  # beside STUB_LOG, after which `show` serves TASK_SHOW_JSON_AFTER_UPDATE when set
  # (modelling a write the board lost) — same shape as fast_check_test's TASK stub.
  def write_cli_stub(dir, name, marker)
    stub = File.join(dir, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["#{marker}", *ARGV].join("\\t")) }
      sentinel = ENV.fetch("STUB_LOG") + ".updated"
      File.write(sentinel, "1") if ARGV.first == "update"
      if ARGV.first == "show"
        after = ENV["TASK_SHOW_JSON_AFTER_UPDATE"].to_s
        if !after.empty? && File.exist?(sentinel)
          puts after
        elsif ENV["TASK_SHOW_JSON"]
          puts ENV["TASK_SHOW_JSON"]
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
