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

  def test_default_merge_replaces_fast_cert_evidence_too
    # bin/full-suite-check's default merge: a fresh FULL cert supersedes any prior
    # fast cert (EVIDENCE_LANES is the default replace set).
    merged = FullSuiteGate.merge_evidence(["[fast-cert@oldfp] x"], ["[full-suite@newfp] y"])
    refute_includes merged, "[fast-cert@oldfp] x"
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
  def run_check(dir, args: ["--print"], fail_token: "", extra_env: {})
    log = File.join(dir, "stub.log")
    lane = write_stub(dir, "lane-stub", "LANE")
    gate = write_stub(dir, "gate-stub", "GATE")
    task = write_stub(dir, "task-stub", "TASK")
    # SessionEnv.neutralized: the child must name NO agent session — bin/fast-check
    # shells to bin/task and the gate. See test/support/session_env.rb.
    env = SessionEnv.neutralized({
      "FAST_CHECK_ROOT" => dir,
      "FAST_CHECK_DIFF_BASE" => "HEAD",
      "FAST_CHECK_SPINE" => File.join(dir, "spine.yml"),
      "FAST_CHECK_TEST_DB_RESET_CMD" => "true",
      "FAST_CHECK_TEST_CMD" => "#{lane.shellescape} TEST",
      "FAST_CHECK_RUBOCOP_CMD" => "#{lane.shellescape} RUBOCOP",
      "FAST_CHECK_GATE_BIN" => gate,
      "FAST_CHECK_TASK_BIN" => task,
      "STUB_LOG" => log,
      "FAIL_TOKEN" => fail_token
    }.merge(extra_env))
    out = IO.popen(env, "#{BIN.shellescape} #{args.map(&:shellescape).join(' ')} 2>/dev/null", &:read)
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

  def test_db_prepare_failure_aborts_before_any_lane
    with_repo do |dir, _|
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_TEST_DB_RESET_CMD" => "false" })
      assert_equal 1, code, out
      assert_empty lane_calls(lines, "TEST"), "no lane runs against a broken test DB"
      refute_match(/\[fast-cert@/, out)
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
      dor_fp = IO.popen(SessionEnv.neutralized("DOR_CHECK_DIFF_ROOT" => dir),
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
      assert_equal %w[test-db-prepare mapped-tests spine rubocop-changed], sop_names
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
end
