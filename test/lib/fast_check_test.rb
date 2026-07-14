# frozen_string_literal: true

# Harness tests for bin/fast-check — the G1 FAST cert runner (diff-mapped tests
# + core spine + rubocop on changed files, recording "[fast-cert@<fp>]"
# fingerprint-bound evidence). Mirrors test/lib/full_suite_check_test.rb's seam
# pattern: the script is shelled with its lanes stubbed via FAST_CHECK_* env vars
# against throwaway git repos, so the ORCHESTRATION is exercised without a real
# Rails run; the board/gate CLIs are stubbed via FAST_CHECK_TASK_BIN /
# FAST_CHECK_GATE_BIN so the durable-record writes are asserted without a board.
# Selection logic itself is unit-tested in test/lib/fast_cert_test.rb.
# Run directly:
#   ruby -Itest test/lib/fast_check_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "../support/session_env"
require_relative "../../bin/lib/full_suite_gate"

class FastCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/fast-check", __dir__)
  DOR = File.expand_path("../../bin/dor-check", __dir__)

  # THE CHILD CERT HAS NO DATABASE. Say so, or it inherits ours.
  #
  # Every test here spawns the REAL bin/fast-check against a THROWAWAY git repo in a
  # tmpdir — a repo with no database anywhere near it. But the child inherits this
  # process's env, and a worktree's `bin/rails test` exports TEST_DATABASE_URL (from
  # .env.test.local) AND holds an open connection to that database the moment anything
  # in the run loads test_helper. So the child cert resolved the DB from the INHERITED
  # env (test_db_url reads ENV before the root's dotenv), probed OUR worktree's test DB,
  # found one foreign backend holding it — THE TEST RUNNER THAT SPAWNED IT — and did
  # exactly what it is built to do: REFUSED. Exit 1.
  #
  #   fast-check: REFUSING — the test DB mcritchie_studio_test_<worktree> is held by 1
  #   other session(s): pid 505 (bin/rails).            # ← pid 505 IS the test runner
  #
  # 27 tests across this file and full_suite_check_test.rb went red that way under
  # `bin/rails test test/lib/` (the whole dir in ONE process), and stayed green when run
  # alone — because a bare minitest file opens no AR connection and there is then nothing
  # holding the DB. That difference reads as a spooky "inter-file interaction"; it is
  # only ever this, and it will red-light the cert's own mapped lane for anyone whose
  # diff touches these files alongside an AR-touching test.
  #
  # The fix is to stop lying to the child: this tmpdir repo has NO database. Unset the
  # inherited URL (test_db_url → nil → foreign_backends → [], no probe at all) and point
  # the probe at a psql that does not exist. cert_orphan_guard_reaper_test.rb already
  # carried this defence (its NO_DB_ENV); it simply never reached the two harness files.
  # The DB backstop is covered on its own terms there and in cert_orphan_guard_test.rb.
  NO_AMBIENT_DB = { "TEST_DATABASE_URL" => nil, "CERT_GUARD_PSQL" => "/nonexistent/psql" }.freeze

  # THE one place a child env is built in this file. Both scrubs — the agent session
  # (SessionEnv) and the ambient database (above) — are applied HERE, so a new spawn
  # site cannot quietly acquire either leak; patching five call sites one at a time is
  # how the fifth gets missed. Same discipline the guard itself now follows: ONE
  # predicate, not a rule repeated wherever someone remembers it.
  def child_env(overrides = {})
    SessionEnv.neutralized(NO_AMBIENT_DB.merge(overrides))
  end

  # --- [unit] the harness's own child env --------------------------------------------

  def test_child_env_never_hands_the_child_our_database
    env = child_env("FAST_CHECK_ROOT" => "/tmp/whatever")

    assert env.key?("TEST_DATABASE_URL"), "the key must be PRESENT and nil — that is what UNSETS it"
    assert_nil env["TEST_DATABASE_URL"],
              "a child cert rooted at a throwaway repo must not inherit THIS suite's test DB: it would " \
              "probe our database, find the test runner that spawned it holding a connection, and refuse"
    assert_nil env["CLAUDE_CODE_SESSION_ID"], "…and it still must not inherit the live agent session"
    assert_equal "/tmp/whatever", env["FAST_CHECK_ROOT"], "overrides still pass through"
  end

  # --- [unit] merge_evidence with lanes: the fast writer must not drop full evidence

  def test_fast_lane_merge_replaces_only_prior_fast_cert_lines
    existing = [
      "[unit] bin/rails test test/foo_test.rb",
      "[full-suite@fullfp] tests green",
      "[rubocop@fullfp] lint clean",
      "[fast-cert@oldfp] stale fast cert",
      "[full-suite-bypass] tracked elsewhere"
    ]
    merged = FullSuiteGate.merge_evidence(existing, ["[fast-cert@newfp] fresh"],
                                          lanes: [FullSuiteGate::FAST_LANE])

    assert_includes merged, "[unit] bin/rails test test/foo_test.rb"
    assert_includes merged, "[full-suite@fullfp] tests green", "full evidence must survive a fast write"
    assert_includes merged, "[rubocop@fullfp] lint clean"
    assert_includes merged, "[full-suite-bypass] tracked elsewhere"
    assert_includes merged, "[fast-cert@newfp] fresh"
    refute_includes merged, "[fast-cert@oldfp] stale fast cert"
  end

  def test_default_merge_supersedes_only_the_lanes_supplied
    # The write rule (lib/cert_evidence.rb): a writer supersedes exactly the lanes
    # it SUPPLIES evidence for. bin/full-suite-check stamps full-suite + rubocop,
    # so those lanes are replaced and a prior fast-cert line is carried over — it
    # used to be deleted, but the board now preserves any lane a write does not
    # address (that is what stops `--checks` from wiping a cert), so deleting it
    # here would only make the CLI disagree with what the board stores. The lingering
    # line is inert: `ok` is graded off LANES (full-suite + rubocop) alone.
    merged = FullSuiteGate.merge_evidence(["[fast-cert@oldfp] x"], ["[full-suite@newfp] y"])
    assert_includes merged, "[fast-cert@oldfp] x"
    assert_includes merged, "[full-suite@newfp] y"
  end

  def test_evaluate_grades_the_fast_lane_alongside_the_full_lanes
    checks = ["[fast-cert@abc1234] fast green"]
    assert_equal :fresh, FullSuiteGate.lane_status(checks, FullSuiteGate::FAST_LANE, "abc1234")
    assert_equal :stale, FullSuiteGate.lane_status(checks, FullSuiteGate::FAST_LANE, "fffffff")
    assert_equal :missing, FullSuiteGate.lane_status([], FullSuiteGate::FAST_LANE, "abc1234")
  end

  # --- fixtures --------------------------------------------------------------------

  # A temp git repo shaped like an app: a changed model + its convention test, a
  # spine test + spine config, and one committed baseline. Yields the dir.
  def with_repo
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      write.call("app/models/base.rb", "class Base; end\n")
      write.call("test/models/widget_test.rb", "widget test\n")
      write.call("test/models/spine_core_test.rb", "spine test\n")
      write.call("spine.yml", "spine:\n  - test/models/spine_core_test.rb\n")
      # The harness writes its stub CLIs and their log INTO the repo dir, so without
      # this they read as untracked dirt to the dirty-tree guard (cert_tree_guard.rb)
      # — test tooling, not uncommitted work. Ignoring them keeps the fixture's dirt
      # HONEST: the only uncommitted file is the branch diff itself (widget.rb below).
      write.call(".gitignore", "stub.log\n*-stub\n")
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m init")
      # The branch diff: a changed model that maps to test/models/widget_test.rb.
      write.call("app/models/widget.rb", "class Widget; end\n")
      yield dir, write
    end
  end

  # A stub CLI: appends "<MARKER>\t<argv...>" to STUB_LOG_<MARKER>; exits 1 when
  # FAIL_TOKEN is set and appears in its argv, else 0. For the TASK stub, `show`
  # prints TASK_SHOW_JSON so the runner's read-merge-write can be exercised.
  def write_stub(dir, name, marker)
    stub = File.join(dir, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["#{marker}", *ARGV].join("\\t")) }
      if ARGV.first == "show" && ENV["TASK_SHOW_JSON"]
        puts ENV["TASK_SHOW_JSON"]
      end
      token = ENV["FAIL_TOKEN"].to_s
      exit(!token.empty? && ARGV.join(" ").include?(token) ? 1 : 0)
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # Run bin/fast-check against `dir` with every seam stubbed. Returns
  # [stdout, exitcode, log_lines] where log_lines is the parsed stub log
  # ([[marker, argv...], ...] in call order).
  #
  # implicit_root: true drops the FAST_CHECK_ROOT override and runs the script
  # WITH `dir` as its cwd instead — the root resolves from the cwd git toplevel,
  # exercising the task-root guard (which an explicit override bypasses). stderr
  # is merged into stdout there so the refusal message is assertable.
  def run_check(dir, args: ["--print"], fail_token: "", extra_env: {}, implicit_root: false)
    log = File.join(dir, "stub.log")
    lane = write_stub(dir, "lane-stub", "LANE")
    gate = write_stub(dir, "gate-stub", "GATE")
    task = write_stub(dir, "task-stub", "TASK")
    # child_env: the child must name NO agent session (bin/fast-check shells to bin/task
    # and the gate — test/support/session_env.rb) and must not inherit our test DB
    # (NO_AMBIENT_DB). Both scrubs live in child_env; never build a child env by hand.
    env = child_env({
      "FAST_CHECK_ROOT" => dir,
      "FAST_CHECK_DIFF_BASE" => "HEAD",
      "FAST_CHECK_SPINE" => File.join(dir, "spine.yml"),
      "FAST_CHECK_TEST_PREPARE_CMD" => "true",
      "FAST_CHECK_TEST_CMD" => "#{lane.shellescape} TEST",
      "FAST_CHECK_RUBOCOP_CMD" => "#{lane.shellescape} RUBOCOP",
      "FAST_CHECK_GATE_BIN" => gate,
      "FAST_CHECK_TASK_BIN" => task,
      "STUB_LOG" => log,
      "FAIL_TOKEN" => fail_token
    }.merge(extra_env))
    cmd = "#{BIN.shellescape} #{args.map(&:shellescape).join(' ')}"
    out =
      if implicit_root
        env.delete("FAST_CHECK_ROOT")
        IO.popen(env, "#{cmd} 2>&1", chdir: dir, &:read)
      else
        IO.popen(env, "#{cmd} 2>/dev/null", &:read)
      end
    code = $?.exitstatus
    lines = File.exist?(log) ? File.readlines(log, chomp: true).map { |l| l.split("\t") } : []
    [out, code, lines]
  end

  def lane_calls(lines, first_arg)
    lines.select { |l| l[0] == "LANE" && l[1] == first_arg }.map { |l| l[2..] }
  end

  # --- [unit] lanes + selection wiring ----------------------------------------------

  def test_green_run_prints_fingerprint_bound_fast_cert_evidence
    with_repo do |dir, _|
      out, code, = run_check(dir)
      assert_equal 0, code, out
      assert_match(/\A\[fast-cert@[0-9a-f]{7,64}\]/, out)
      assert_match(/full suite runs on CI/, out)
    end
  end

  def test_mapped_lane_gets_the_diff_mapped_test_and_spine_lane_gets_the_spine
    with_repo do |dir, _|
      _, code, lines = run_check(dir)
      assert_equal 0, code
      tests = lane_calls(lines, "TEST")
      assert_equal 2, tests.size, "one mapped-tests run + one spine run: #{lines.inspect}"
      assert_equal ["test/models/widget_test.rb"], tests[0], "mapped lane runs the diff-mapped test"
      assert_equal ["test/models/spine_core_test.rb"], tests[1], "spine lane runs the configured spine"
    end
  end

  def test_rubocop_lane_is_scoped_to_changed_lintable_files_only
    with_repo do |dir, _|
      _, code, lines = run_check(dir)
      assert_equal 0, code
      lint = lane_calls(lines, "RUBOCOP")
      assert_equal 1, lint.size
      assert_equal ["app/models/widget.rb"], lint[0],
                   "rubocop runs on the CHANGED file only — never the whole repo"
    end
  end

  def test_mapped_tests_already_covered_by_the_spine_run_once
    with_repo do |dir, write|
      # The diff now ALSO touches the spine-covered model: its mapped test is the
      # spine test itself, so the mapped lane must not re-run it.
      write.call("app/models/spine_core.rb", "class SpineCore; end\n")
      _, code, lines = run_check(dir)
      assert_equal 0, code
      tests = lane_calls(lines, "TEST")
      assert_equal ["test/models/widget_test.rb"], tests[0], "spine-covered mapped test dropped from the mapped lane"
      assert_equal ["test/models/spine_core_test.rb"], tests[1]
    end
  end

  def test_red_test_lane_exits_nonzero_and_records_nothing
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "widget_test")
      assert_equal 1, code, out
      refute_match(/\[fast-cert@/, out, "a red lane must not certify")
    end
  end

  def test_red_rubocop_lane_exits_nonzero_and_records_nothing
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "RUBOCOP")
      assert_equal 1, code, out
      refute_match(/\[fast-cert@/, out)
    end
  end

  def test_doc_only_diff_skips_test_and_rubocop_lanes_but_still_runs_the_spine
    with_repo do |dir, write|
      write.call("docs/notes.md", "notes\n")
      env = { "FAST_CHECK_CHANGED_FILES" => "docs/notes.md" }
      out, code, lines = run_check(dir, extra_env: env, fail_token: "RUBOCOP")
      # rubocop's stub would FAIL if invoked — a doc-only diff must skip it.
      assert_equal 0, code, out
      assert_empty lane_calls(lines, "RUBOCOP"), "no lintable files → rubocop lane skipped"
      assert_equal [["test/models/spine_core_test.rb"]], lane_calls(lines, "TEST"),
                   "the spine still runs when nothing maps"
      assert_match(/\[fast-cert@/, out)
    end
  end

  def test_test_prepare_failure_aborts_before_any_lane
    with_repo do |dir, _|
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_TEST_PREPARE_CMD" => "false" })
      assert_equal 1, code, out
      assert_empty lane_calls(lines, "TEST"), "no lane runs against an unprepared test env"
      refute_match(/\[fast-cert@/, out)
    end
  end

  # --- [unit] the virgin-tree bundled-asset regression -------------------------------
  #
  # A fake `bin/rails` that models the two Rails behaviours this cert depends on:
  #
  #   1. `test:prepare` is the hook a CSS/JS bundler enhances to BUILD its artifact
  #      (tailwindcss-rails: `Rake::Task["test:prepare"].enhance(["tailwindcss:build"])`).
  #      NOTHING else builds it -- `db:test:prepare` does not (tailwindcss enhances it
  #      only as a FALLBACK, when test:prepare is undefined).
  #   2. Propshaft raises "The asset ... is not present in the asset pipeline" when a
  #      view's stylesheet_link_tag target was never built.
  #
  # The fake fails its `test` lane ONLY on the missing artifact -- never on the paths --
  # so the test reproduces the exact production symptom (a virgin worktree, where the
  # gitignored app/assets/builds/ holds nothing but .keep) and nothing else.
  def write_fake_rails(dir)
    rails = File.join(dir, "bin", "rails")
    FileUtils.mkdir_p(File.dirname(rails))
    File.write(rails, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"
      built = File.join(Dir.pwd, "app/assets/builds/tailwind.css")
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["RAILS", *ARGV].join("\\t")) }
      if ARGV.include?("test:prepare")
        FileUtils.mkdir_p(File.dirname(built))
        File.write(built, "/* built by the test:prepare hook */")
      end
      if ARGV.first == "test" && !File.exist?(built)
        warn 'The asset "tailwind.css" is not present in the asset pipeline.'
        exit 1
      end
      exit 0
    RUBY
    FileUtils.chmod("+x", rails)
  end

  # Regression (build-assets-on-worktree-bringup): fast-check's test lanes pass EXPLICIT
  # FILE PATHS, and Rails SKIPS its own test:prepare whenever an argument looks like a
  # path -- Rails::Command::TestCommand runs it only `if self.args.none?(
  # EXACT_TEST_ARGUMENT_PATTERN)`. So the bundler hook that an ARGLESS `bin/rails test`
  # fires for free (CI, bin/full-suite-check -- all green; the release gate workspaces
  # prep their own env since gate-workspace-skips-test-prepare, PR #522) never fires
  # here, and on a virgin worktree every
  # view-rendering test errored with
  # `The asset "tailwind.css" is not present in the asset pipeline`: ~77 red on a
  # ci.yml-only or docs-only diff. A G1 cert that reports an ENV GAP as a test
  # regression is lying, so the cert must run test:prepare ITSELF.
  #
  # Note this deliberately does NOT stub FAST_CHECK_TEST_PREPARE_CMD / FAST_CHECK_TEST_CMD
  # (a nil value UNSETS the var for the child): the DEFAULT lane commands are the thing
  # under test — the bug lived in the default.
  def test_prepare_lane_builds_bundled_assets_before_the_path_arg_test_lanes
    with_repo do |dir, _|
      write_fake_rails(dir)
      out, code, lines = run_check(dir, extra_env: {
                                     "FAST_CHECK_TEST_PREPARE_CMD" => nil, # use the real default
                                     "FAST_CHECK_TEST_CMD" => nil,         # use the real default
                                     "FAST_CHECK_RUBOCOP_CMD" => "true"
                                   })
      rails = lines.select { |l| l[0] == "RAILS" }.map { |l| l[1..] }

      assert_equal ["db:test:prepare", "test:prepare"], rails[0],
                   "the prepare lane must run Rails' test:prepare hook (which builds the bundled " \
                   "CSS) as well as the test DB prepare — the path-arg test lanes below will not"
      assert_path_exists File.join(dir, "app/assets/builds/tailwind.css"),
                         "prepare must leave the bundled asset on disk for the lanes that follow"
      assert_equal ["test", "test/models/widget_test.rb"], rails[1], "mapped lane still runs by path"
      assert_equal ["test", "test/models/spine_core_test.rb"], rails[2], "spine lane still runs by path"
      assert_equal 0, code, "a virgin tree must certify GREEN, not red on a missing asset:\n#{out}"
      assert_match(/\A\[fast-cert@/, out)
    end
  end

  def test_list_mode_prints_the_selection_without_running_anything
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["--list"])
      assert_equal 0, code, out
      assert_match(%r{mapped\s+test/models/widget_test\.rb}, out)
      assert_match(%r{spine\s+test/models/spine_core_test\.rb}, out)
      assert_match(%r{lint\s+app/models/widget\.rb}, out)
      assert_empty lines, "--list must not run lanes or emit gate/task writes"
    end
  end

  def test_fingerprint_matches_dor_check_view
    # The writer and the reader must agree, or fast-cert evidence never validates.
    with_repo do |dir, _|
      out, = run_check(dir)
      runner_fp = out[/@([0-9a-f]{7,64})\]/, 1]
      dor_fp = IO.popen(child_env("DOR_CHECK_DIFF_ROOT" => dir),
                        "#{DOR} --suite-fingerprint 2>/dev/null", &:read).strip
      assert_equal dor_fp, runner_fp
    end
  end

  # --- [integration] durable-record writes: task evidence + G1 gate markers ---------

  SHOW_JSON = JSON.generate(
    "metadata" => { "devops" => { "checks_run" => [
      "[unit] bin/rails test test/models/widget_test.rb",
      "[full-suite@fullfp] tests green",
      "[fast-cert@oldfp] prior fast cert"
    ] } }
  )

  def test_recording_merges_evidence_preserving_tiers_and_full_cert_lines
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code, out

      update = lines.find { |l| l[0] == "TASK" && l[1] == "update" }
      refute_nil update, "green run records evidence via task update: #{lines.inspect}"
      checks = update.each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      assert_includes checks, "[unit] bin/rails test test/models/widget_test.rb", "tier tags preserved"
      assert_includes checks, "[full-suite@fullfp] tests green", "full-cert evidence preserved"
      assert(checks.any? { |c| c =~ /\A\[fast-cert@[0-9a-f]{7,64}\]/ }, "fresh fast-cert line recorded")
      refute_includes checks.join("\n"), "[fast-cert@oldfp]", "prior fast-cert line replaced"
    end
  end

  def test_green_run_opens_g1_appends_one_sop_per_lane_and_self_closes_success
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code
      gate = lines.select { |l| l[0] == "GATE" }
      assert_equal %w[open sop sop sop sop close], gate.map { |l| l[1] },
                   "open + one sop per lane + a self-close on green (cert owns g1_cert now, " \
                   "not dor-check): #{gate.inspect}"
      sop_names = gate.select { |l| l[1] == "sop" }.map { |l| l[l.index("--sop") + 1] }
      assert_equal %w[test-prepare mapped-tests spine rubocop-changed], sop_names
      close = gate.find { |l| l[1] == "close" }
      assert_includes close, "--success", "the green cert closes g1_cert success itself"
      assert(gate.all? { |l| l[2] == "task" && l[3] == "task-x" && l[4] == "g1_cert" })
    end
  end

  def test_red_lane_closes_g1_failed
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], fail_token: "widget_test",
                                      extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 1, code
      close = lines.find { |l| l[0] == "GATE" && l[1] == "close" }
      refute_nil close, "a red lane closes the G1 attempt: #{lines.inspect}"
      assert_includes close, "--failed"
    end
  end

  def test_print_mode_emits_no_gate_or_task_writes
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x", "--print"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code, out
      assert_empty(lines.select { |l| %w[GATE TASK].include?(l[0]) },
                   "--print is a dry run — no durable-record writes: #{lines.inspect}")
      assert_match(/\[fast-cert@/, out, "the evidence line still prints")
    end
  end

  def test_cert_checkpoints_bound_the_run_in_non_print_mode
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code
      checkpoints = lines.select { |l| l[0] == "TASK" && l[1] == "checkpoint" }
      assert_equal [%w[started], %w[completed]],
                   checkpoints.map { |l| [l[l.index("--status") + 1]] },
                   "a cert checkpoint opens and closes the Local Certification window"
    end
  end

  def test_unreadable_task_checks_aborts_without_writing
    with_repo do |dir, _|
      # TASK stub fails on `show` → the runner must NOT blind-write --checks.
      out, code, lines = run_check(dir, args: ["task-x"],
                                        extra_env: { "TASK_SHOW_JSON" => "", "FAIL_TOKEN" => "show" })
      assert_equal 1, code, out
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" },
             "a blind --checks write would wipe tier tags — abort instead")
    end
  end

  # --- [integration] task-root guard: the cert must root at the TASK's tree ---------
  # Regression for the 2026-07-12 fail-GREEN: run from the hub primary (on main),
  # the cert rooted at the cwd's git toplevel and green-certified MAIN's tree for
  # an unrelated task. With a task slug and an IMPLICIT root (cwd, no
  # FAST_CHECK_ROOT), the cert must verify the root IS the task's tree —
  # its checked-out branch is the task's branch, or it is the task's
  # .worktrees/<worktree_slug> dir — and REFUSE otherwise (bin/lib/cert_root_guard.rb).

  GUARD_JSON = JSON.generate(
    "metadata" => { "devops" => {
      "branch" => "feat/task-x", "worktree_slug" => "task-x", "checks_run" => []
    } }
  )

  def test_wrong_root_cert_is_refused_before_any_lane_runs
    with_repo do |dir, _|
      # cwd = a tree on its default branch (main/master) — NOT task-x's tree.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 1, code, "a wrong-root cert must refuse, not green-certify: #{out}"
      assert_match(/not task-x's tree/, out, "the refusal names the task")
      assert_match(%r{feat/task-x}, out, "the refusal names the expected branch")
      refute_match(/\[fast-cert@/, out, "no evidence for a tree the task never touched")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  def test_task_branch_checkout_certifies_without_a_root_override
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # COMMIT the branch diff first — the dirty-tree guard below now enforces what
      # was previously only a house rule, so the cert is the LAST build step. Diffing
      # from HEAD~1 keeps widget.rb in the mapped lane now that it is committed.
      commit_all(dir)
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON,
                                                "FAST_CHECK_DIFF_BASE" => "HEAD~1" })
      assert_equal 0, code, "the task's own tree certifies from cwd with no override: #{out}"
      assert_match(/\[fast-cert@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
      assert_includes lane_calls(lines, "TEST").flatten, "test/models/widget_test.rb",
                      "the mapped lane still selects off the diff once it is committed"
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
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # The RIGHT tree (task-x's branch) — but widget.rb is still uncommitted.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })

      assert_equal 1, code, "an uncommitted tree must refuse, not green-certify: #{out}"
      assert_match(/DIRTY/, out)
      assert_match(%r{app/models/widget\.rb}, out, "the refusal NAMES the uncommitted file")
      assert_match(/commit/i, out, "the refusal states the fix")
      refute_match(/\[fast-cert@/, out, "no evidence for a tree that is not on the PR")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  def test_stale_mtime_tree_still_certifies
    # THE FALSE POSITIVE the guard must not become. A tracked file rewritten with
    # IDENTICAL content has a fresh mtime, leaving git's stat cache stale — which the
    # cheap dirty reads (git diff-index) call MODIFIED. On the CERT path a false
    # refusal blocks every handoff, so the guard refreshes the index before reading
    # it. Unit-level proof, including the index-refresh mechanism itself, lives in
    # test/lib/cert_tree_guard_test.rb.
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      commit_all(dir)

      tracked = File.join(dir, "app/models/widget.rb")
      body = File.read(tracked)
      File.write(tracked, body)                                       # byte-identical rewrite
      FileUtils.touch(tracked, mtime: Time.now + (10 * 365 * 24 * 3600))
      refute system("git", "-C", dir, "diff-index", "--quiet", "HEAD", out: File::NULL, err: File::NULL),
             "fixture check: the index must actually BE stat-stale, else this proves nothing"

      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON,
                                                "FAST_CHECK_DIFF_BASE" => "HEAD~1" })

      assert_equal 0, code, "a stat-stale index is a CLEAN tree — it must still certify: #{out}"
      refute_match(/DIRTY/, out, "a file nobody edited must never be reported as uncommitted work")
      assert_match(/\[fast-cert@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
    end
  end

  # --- [integration] the TIMEOUT-ORPHAN regression ------------------------------------
  #
  # Live bug, 2026-07-13. bin/fast-check outran the harness's 120s Bash timeout (a
  # diff that maps to ~120 test files runs 7+ minutes). The timeout killed the cert
  # PARENT — and the `bin/rails test` grandchild SURVIVED it, reparented to launchd
  # (PPID 1), still holding an open PG connection to the worktree's test DB:
  #
  #   41578  1  41538  R  ruby bin/rails test test/models/task_test.rb ...
  #   pid 41763 | idle in transaction | bin/rails
  #
  # Every retry then died in the test-prepare lane with
  #
  #   PG::ObjectInUse: database "..._test_..." is being accessed by other users
  #   DETAIL: There is 1 other session using the database.
  #   Tasks: TOP => db:test:load_schema => db:test:purge
  #
  # which fast-check reported as "USUALLY an ENV gap ... NOT a regression in your
  # diff" — never NAMING the orphan. So the agent retried blindly: three cert
  # attempts, 35 minutes, zero board progress, while its ClaimLease heartbeat kept
  # the task looking healthy on the board.
  #
  # Root cause: `system(env, cmd, chdir: root)` runs the lane in the cert's OWN
  # process group and installs no signal handler, so a signal aimed at the cert
  # never reaches the suite. The cert must (a) put each lane in its own process
  # GROUP and reap that group when it dies, and (b) detect an orphan it could not
  # prevent and say its name.

  # A lane stub that records its pid and then hangs — stands in for `bin/rails test`
  # holding the test DB. Returns the path; the pid lands in <dir>/lane.pid.
  def write_hanging_lane(dir)
    lane = File.join(dir, "hanging-lane")
    File.write(lane, <<~RUBY)
      #!#{RbConfig.ruby}
      File.write(File.join(#{dir.inspect}, "lane.pid"), Process.pid.to_s)
      sleep 120
    RUBY
    FileUtils.chmod("+x", lane)
    lane
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # Has a process WE spawned actually exited? `kill(0)` cannot answer this for our own
  # children: a killed child lingers as a ZOMBIE whose pid still answers signal 0 until
  # its parent reaps it. (A real orphan is reparented to launchd, which reaps it at once
  # — the zombie is an artefact of the test owning the process.) So we wait on it.
  def exited?(pid, timeout: 10)
    deadline = Time.now + timeout
    loop do
      return true if Process.waitpid(pid, Process::WNOHANG)
      return false if Time.now > deadline

      sleep 0.1
    end
  rescue Errno::ECHILD
    true # already reaped
  end

  def wait_until(timeout: 10)
    deadline = Time.now + timeout
    sleep 0.1 until yield || Time.now > deadline
    yield
  end

  # THE regression: kill the cert the way a harness timeout does, and the suite it
  # spawned must not outlive it. Before the fix the lane survived as an orphan
  # holding the test DB; after it, the cert reaps its whole process group.
  def test_a_killed_cert_does_not_orphan_the_suite_it_spawned
    with_repo do |dir, _|
      lane = write_hanging_lane(dir)
      env = child_env(
        {
          "FAST_CHECK_ROOT" => dir,
          "FAST_CHECK_DIFF_BASE" => "HEAD",
          "FAST_CHECK_SPINE" => File.join(dir, "spine.yml"),
          "FAST_CHECK_TEST_PREPARE_CMD" => "true",
          "FAST_CHECK_TEST_CMD" => lane.shellescape,
          "FAST_CHECK_RUBOCOP_CMD" => "true",
          "FAST_CHECK_SKIP_ORPHAN_GUARD" => "1" # the guard is tested separately below
        }
      )
      cert = Process.spawn(env, BIN, "--print", chdir: dir, out: File::NULL, err: File::NULL)
      pid_file = File.join(dir, "lane.pid")
      assert wait_until { File.exist?(pid_file) }, "the lane never started"
      lane_pid = File.read(pid_file).to_i
      assert alive?(lane_pid), "the lane should be running before we kill the cert"

      # The harness timeout: signal the cert PROCESS, not the group.
      Process.kill("TERM", cert)
      Process.waitpid(cert)

      reaped = wait_until(timeout: 10) { !alive?(lane_pid) }
      assert reaped,
             "ORPHAN: the suite (pid #{lane_pid}) outlived the cert that spawned it. It keeps the " \
             "worktree test DB open, and every retry dies on PG::ObjectInUse blaming 'an ENV gap'."
    ensure
      Process.kill("KILL", lane_pid) if lane_pid && alive?(lane_pid)
    end
  end

  # --- [integration] the guard: an orphan we could NOT prevent must be NAMED ----------
  #
  # A SIGKILLed cert runs no handler, so prevention alone can never be complete. The
  # next cert therefore reads the runlock the previous one left. A dead cert pid whose
  # process group is still alive is NOT, by itself, proof of an abandoned suite: a pgid
  # is a recyclable integer and this lock is repo-relative (it outlives reboots), so the
  # number may since have been handed to a stranger. The lock therefore records the OS's
  # start time for the group leader, and the guard reaps only what that identity proves
  # is ours. Anything else is refused or discarded — never killed, never silently
  # blocked.

  # The OS's own start-time record, read independently of the code under test — a
  # fixture that builds itself with the implementation it is checking proves nothing.
  def os_start_time(pid)
    # 2>/dev/null: the dead-cert fixtures name pids like 999_999 on purpose, and `ps`
    # grumbles "process id too large" onto stderr. A cert log is a signal; do not
    # teach anyone to read past noise in it.
    out = `ps -p #{pid.to_i} -o lstart= 2>/dev/null`.strip.squeeze(" ")
    out.empty? ? nil : out
  end

  # The runlock as CertProcess writes it: WHO, and — the whole point — WHEN.
  # `pgid_started_at:` overrides the identity, to forge the two locks that matter:
  # a recycled pgid (a start time that is not this process's) and a legacy lock
  # (`nil` — written before the guard recorded identity at all).
  # The runlock lives in the GIT DIR, never in the working tree — a lock inside the tree
  # is untracked dirt in any repo that does not ignore `tmp/`, and the cert now refuses a
  # dirty tree (see bin/lib/cert_orphan_guard.rb#lock_path). Resolved here by asking git
  # DIRECTLY, not by calling CertOrphanGuard: a fixture that builds itself with the
  # implementation it is checking proves nothing.
  def git_dir(dir)
    out = `git -C #{dir.shellescape} rev-parse --absolute-git-dir 2>/dev/null`.strip
    refute_empty out, "the fixture repo must be a git repo"
    out
  end

  def write_lock(dir, cert_pid:, pgid:, pgid_started_at: :real, cert_started_at: :real)
    started = pgid_started_at == :real ? os_start_time(pgid) : pgid_started_at
    cert_started = cert_started_at == :real ? os_start_time(cert_pid) : cert_started_at
    lock = File.join(git_dir(dir), "cert-run.json")
    FileUtils.mkdir_p(File.dirname(lock))
    File.write(lock, JSON.generate("cert_pid" => cert_pid, "cert_started_at" => cert_started,
                                   "pgid" => pgid, "pgid_started_at" => started, "lane" => "spine",
                                   "db" => "studio_test_x", "started_at" => "2026-07-13T05:00:00Z"))
    lock
  end

  def test_a_leftover_orphan_group_is_named_and_reaped_before_the_lanes_run
    with_repo do |dir, _|
      # An orphan: a live process group whose cert parent is long dead.
      orphan = Process.spawn("sleep 120", pgroup: true)
      orphan_pgid = Process.getpgid(orphan)
      write_lock(dir, cert_pid: 999_999, pgid: orphan_pgid) # 999999 = a pid that is not running

      # implicit_root: runs from `dir` with stderr merged, so the guard's message is assertable.
      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 0, code, "reaping our own orphan is self-healing — the cert proceeds: #{out}"
      assert_match(/#{orphan_pgid}/, out, "the cert must NAME the orphan it reaped, not swallow it")
      assert_match(/NOT a regression in your diff/, out, "an ENV-class condition must say so")
      assert exited?(orphan),
             "the orphan (pgid #{orphan_pgid}) must be REAPED — it is what holds the test DB"
      refute_empty lane_calls(lines, "TEST"), "after reaping, the cert runs normally"
    ensure
      begin
        if orphan
          Process.kill("KILL", orphan)
          Process.waitpid(orphan)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil # already reaped by the guard — which is the point of the test
      end
    end
  end

  def test_a_live_concurrent_cert_is_refused_and_never_killed
    with_repo do |dir, _|
      # NOT an orphan: another cert is genuinely running in this tree. Killing it
      # would be hostile, and running beside it is the known two-suites-on-one-test-DB
      # hazard (it SIGSEGVs Ruby). Refuse — and leave it alone.
      sibling = Process.spawn("sleep 120", pgroup: true)
      write_lock(dir, cert_pid: sibling, pgid: Process.getpgid(sibling))

      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 1, code, "a concurrent cert in the same tree must be refused: #{out}"
      assert_match(/#{sibling}/, out, "the refusal names the running cert")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      assert alive?(sibling), "a LIVE cert must never be killed by the guard"
      refute_match(/\[fast-cert@/, out, "nothing is certified against a contended test DB")
    ensure
      Process.kill("KILL", sibling) if sibling && alive?(sibling)
    end
  end

  def test_a_stale_lock_from_a_fully_dead_cert_never_blocks_a_cert
    with_repo do |dir, _|
      # Nothing survived — the lock is a corpse. It must not refuse a healthy cert.
      write_lock(dir, cert_pid: 999_998, pgid: 999_999)
      out, code, = run_check(dir)
      assert_equal 0, code, "a stale lock must be cleared, not treated as a live claim: #{out}"
      assert_match(/\[fast-cert@/, out)
    end
  end

  def test_a_runlock_whose_pgid_was_RECYCLED_never_kills_the_bystander
    with_repo do |dir, _|
      # THE BLOCKING BUG, end to end through the real bin/fast-check. The lock is days
      # old, its cert is long dead, and the OS has since handed its pgid to an unrelated
      # process. Grading that "alive, therefore mine" made the cert TERM/KILL an innocent
      # bystander and print "ORPHAN REAPED" (caught in review, 2026-07-14).
      #
      # The recorded start time is the tell: it names an instant before this process
      # existed, so the group is provably NOT ours.
      bystander = Process.spawn("sleep 120", pgroup: true)
      bygid = Process.getpgid(bystander)
      write_lock(dir, cert_pid: 999_999, pgid: bygid, pgid_started_at: "Mon Jul  6 18:40:11 2026")

      out, code, lines = run_check(dir, implicit_root: true)

      # NOT `alive?`: a child we killed lingers as a zombie whose pid still answers
      # signal 0, so kill(0) would report a murdered bystander as alive and pass this
      # test on a regression. `exited?` waitpid()s — it cannot be fooled.
      refute exited?(bystander, timeout: 2),
             "THE BLOCKING BUG: fast-check KILLED an innocent process (pid #{bystander}) whose only " \
             "crime was being handed the recycled pgid #{bygid}"
      assert_equal 0, code, "and a stranger's process must not wedge the cert either: #{out}"
      assert_match(/NOT killing it/i, out, "the cert must say out loud that it refused to kill")
      refute_empty lane_calls(lines, "TEST"), "it discards the stale lock and runs normally"
    ensure
      begin
        if bystander
          Process.kill("KILL", bystander)
          Process.waitpid(bystander)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil # already gone — which would mean the regression this test exists to catch
      end
    end
  end

  def test_a_legacy_runlock_with_no_identity_refuses_rather_than_killing_on_a_guess
    with_repo do |dir, _|
      # A lock written before the guard recorded identity (this is what is on disk in
      # every worktree today). Something is alive under that pgid. It might be our
      # stranded suite; it might be the operator's editor. We cannot tell — and a reaper
      # that guesses is worse than no reaper, so a human decides.
      unknown = Process.spawn("sleep 120", pgroup: true)
      ungid = Process.getpgid(unknown)
      write_lock(dir, cert_pid: 999_999, pgid: ungid, pgid_started_at: nil)

      out, code, lines = run_check(dir, implicit_root: true)

      refute exited?(unknown, timeout: 2), "never kill what you cannot prove is yours"
      assert_equal 1, code, "an unprovable claim on the test DB is refused, not walked into: #{out}"
      assert_match(/#{ungid}/, out, "the refusal NAMES what it found")
      assert_match(/rm .*cert-run\.json/, out, "and hands over the way to clear a lock that is not yours")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
    ensure
      begin
        if unknown
          Process.kill("KILL", unknown)
          Process.waitpid(unknown)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil # already gone — which would mean the regression this test exists to catch
      end
    end
  end

  # THE SECOND BUG, end to end through the real bin/fast-check (review, 2026-07-14).
  #
  # A truncated runlock names process group 1. pid 1 (launchd/init) is always alive, so the
  # guard finds live members under that number and REFUSES — correctly. The bug was what it
  # PRINTED while refusing:
  #
  #   If it IS a stranded suite:  kill -TERM -1
  #
  # POSIX defines `kill -TERM -1` as EVERY process the caller may signal. The cert would not
  # fire it — `signalable?` saw to that — and then handed it to a human to paste, in the
  # house's authoritative "here is how to clear it" voice, at the exact moment (35 minutes
  # into a wedge) that a human pastes without reading. The code path was hardened and the
  # COPY path was not, and the copy path is the one with a human on the end of it.
  #
  # This asserts it where an operator actually meets it: on the real cert's real stdout.
  def test_a_runlock_naming_group_1_refuses_without_ever_printing_kill_TERM_minus_1
    with_repo do |dir, _|
      write_lock(dir, cert_pid: 999_999, pgid: 1, pgid_started_at: nil)

      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 1, code, "a runlock naming group 1 is garbage — refuse, never run beside it: #{out}"
      refute_match(/kill\s+(?:-\w+\s+)*-?[01]\b/, out,
                   "THE BUG: the cert refused to FIRE `kill -TERM -1` and then PRINTED it for a human " \
                   "to paste. It signals every process the caller owns. Full output:\n#{out}")
      assert_match(/rm .*cert-run\.json/, out,
                   "a lock naming group 1 is garbage by construction; the only remediation is to discard it")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
    end
  end

  def test_explicit_root_override_bypasses_the_dirty_tree_guard
    # Same contract as the root guard: an EXPLICIT FAST_CHECK_ROOT is the deliberate
    # CI/test seam, so it bypasses. (run_check's default path sets it — that is why
    # every other test in this file certifies against the fixture's uncommitted diff.)
    with_repo do |dir, _|
      out, code, = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 0, code, "an explicitly-declared root still certifies: #{out}"
      refute_match(/DIRTY/, out)
    end
  end

  # Commit everything in `dir` — the fixture's uncommitted branch diff — so the cert
  # runs against a fully-committed HEAD, which the dirty-tree guard now requires.
  def commit_all(dir)
    assert system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
    assert system("git", "-C", dir, "commit", "-qm", "widget", out: File::NULL, err: File::NULL)
  end
end
