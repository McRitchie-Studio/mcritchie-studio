# frozen_string_literal: true

# Standalone test for bin/full-suite-check — the WRITE half of the full-suite gate
# (bin/dor-check is the READ half). It shells out to the script with the two lanes
# stubbed (FULL_SUITE_TEST_CMD / FULL_SUITE_RUBOCOP_CMD) so the orchestration is
# exercised without a real multi-minute `bin/rails test`. Run directly:
#   ruby -Itest test/lib/full_suite_check_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "../../bin/lib/full_suite_gate"

class FullSuiteCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/full-suite-check", __dir__)
  DOR = File.expand_path("../../bin/dor-check", __dir__)

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
  def run_check(dir, test_cmd:, rubocop_cmd:, reset_cmd: "true")
    env = {
      "FULL_SUITE_ROOT" => dir,
      "FULL_SUITE_TEST_DB_RESET_CMD" => reset_cmd,
      "FULL_SUITE_TEST_CMD" => test_cmd,
      "FULL_SUITE_RUBOCOP_CMD" => rubocop_cmd
    }
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
      dor_fp = IO.popen({ "DOR_CHECK_DIFF_ROOT" => dir }, "#{DOR} --suite-fingerprint 2>/dev/null", &:read).strip
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

  # --- [integration] opt-in pre-push hook installer ----------------------------

  def test_install_hook_writes_an_executable_opt_in_pre_push_hook
    with_repo do |dir|
      out = IO.popen({ "FULL_SUITE_ROOT" => dir }, "#{BIN} --install-hook 2>&1", &:read)
      assert_equal 0, $?.exitstatus, out
      hook = File.join(dir, ".git", "hooks", "pre-push")
      assert File.exist?(hook), "pre-push hook should be installed: #{out}"
      assert File.executable?(hook), "pre-push hook should be executable"
      assert_includes File.read(hook), "exec bin/full-suite-check --print"
      # Idempotent: re-running succeeds and leaves a single managed hook.
      out2 = IO.popen({ "FULL_SUITE_ROOT" => dir }, "#{BIN} --install-hook 2>&1", &:read)
      assert_equal 0, $?.exitstatus, out2
      assert_equal 1, File.read(hook).scan("exec bin/full-suite-check --print").size
      # Uninstall removes the managed hook.
      IO.popen({ "FULL_SUITE_ROOT" => dir }, "#{BIN} --uninstall-hook 2>&1", &:read)
      refute File.exist?(hook), "uninstall should remove the managed hook"
    end
  end

  def test_install_hook_refuses_to_clobber_a_foreign_pre_push_hook
    with_repo do |dir|
      hooks = File.join(dir, ".git", "hooks")
      FileUtils.mkdir_p(hooks)
      foreign = File.join(hooks, "pre-push")
      File.write(foreign, "#!/bin/sh\necho not-ours\n")
      out = IO.popen({ "FULL_SUITE_ROOT" => dir }, "#{BIN} --install-hook 2>&1", &:read)
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

  # The session env keys the emit's session gate reads. Neutralize BOTH so the test
  # never inherits the live session; the caller sets CLAUDE_CODE_SESSION_ID.
  SESSION_KEYS = %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID].freeze

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
    env = {
      "FULL_SUITE_ROOT" => dir,
      "FULL_SUITE_TEST_DB_RESET_CMD" => reset_cmd,
      "FULL_SUITE_TEST_CMD" => test_cmd,
      "FULL_SUITE_RUBOCOP_CMD" => rubocop_cmd,
      "FULL_SUITE_AGENT_ACTIVITY" => agent_activity,
      "STUB_LOG" => log
    }
    SESSION_KEYS.each { |k| env[k] = (k == "CLAUDE_CODE_SESSION_ID" ? session : "") }
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
end
