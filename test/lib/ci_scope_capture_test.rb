# frozen_string_literal: true

# Standalone test for bin/ci-scope-capture — the LOCAL-INGESTION half of test-scope
# telemetry: it reads a PR's `gh pr checks` and self-reports one kind=test_scope
# AgentAction per completed CI job through the SAME `bin/agent-activity action` verb
# bin/full-suite-check and bin/release.rb use. It shells out to the script with the
# gh reads stubbed (CI_SCOPE_CHECKS_JSON / CI_SCOPE_HEAD_SHA) and the emit seam
# pointed at a stub that logs argv (CI_SCOPE_AGENT_ACTIVITY), so the parse+emit is
# exercised with NO network. Run directly:
#   ruby -Itest test/lib/ci_scope_capture_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        the parse/normalize/skip/gate/idempotency-key logic, one job at a time.
#   [integration] a full PR fixture (pass/fail/pending/cancel) self-reports the right lanes.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "json"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class CiScopeCaptureTest < Minitest::Test
  BIN = File.expand_path("../../bin/ci-scope-capture", __dir__)

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

  # Shell the helper with the gh reads injected and the emit seam pointed at
  # `agent_activity`. `session` "" ⇒ no session. Returns [out, code, emits] where
  # emits is an Array<Hash> of parsed emit flags (empty when nothing emitted).
  def run_capture(dir, checks_json:, session:, agent_activity: nil, head_sha: "deadbeef", pr: "123")
    agent_activity ||= write_activity_stub(dir)
    # A FRESH log per call — a test may run_capture twice in one dir (a re-read),
    # and a shared log would accumulate and re-read the first call's lines.
    @log_seq = (@log_seq || 0) + 1
    log = File.join(dir, "emit-#{@log_seq}.log")
    env = OutboundSeams.env(
      "CI_SCOPE_CHECKS_JSON" => checks_json,
      "CI_SCOPE_HEAD_SHA" => head_sha,
      "CI_SCOPE_AGENT_ACTIVITY" => agent_activity,
      "STUB_LOG" => log,
      # The fake session this run emits into — blank ⇒ UNSET (no session at all).
      "CLAUDE_CODE_SESSION_ID" => session
    )
    out = IO.popen(env, "#{BIN} #{pr} 2>/dev/null", &:read)
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

  def checks(*rows)
    JSON.generate(rows.map do |name, bucket, started, completed|
      { "name" => name, "bucket" => bucket, "startedAt" => started, "completedAt" => completed }
    end)
  end

  # --- [unit] one verdict per pass/fail job, tagged correctly ------------------

  def test_emits_a_tagged_test_scope_action_per_pass_or_fail_job
    Dir.mktmpdir do |dir|
      json = checks(
        ["test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:05:30Z"],
        ["lint", "fail", "2026-07-06T10:00:00Z", "2026-07-06T10:00:45Z"]
      )
      _out, code, emits = run_capture(dir, checks_json: json, session: "fake-sess")
      assert_equal 0, code
      assert_equal %w[ci_test ci_lint], emits.map { |e| e["event-slug"] }
      emits.each { |e| assert_equal "test_scope", e["kind"] }
      test_emit = emits.find { |e| e["event-slug"] == "ci_test" }
      assert_equal "pass", test_emit["result-slug"]
      assert_equal "330000", test_emit["duration-ms"], "5m30s in milliseconds"
      assert_equal "ci:123:deadbeef:test", test_emit["idempotency-key"]
      lint_emit = emits.find { |e| e["event-slug"] == "ci_lint" }
      assert_equal "fail", lint_emit["result-slug"]
      assert_equal "45000", lint_emit["duration-ms"]
    end
  end

  def test_skips_pending_skipping_and_cancel_buckets
    Dir.mktmpdir do |dir|
      json = checks(
        ["test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:01:00Z"],
        ["scan_js", "pending", "2026-07-06T10:00:00Z", ""],
        ["scan_ruby", "skipping", "", ""],
        ["deploy", "cancel", "2026-07-06T10:00:00Z", "2026-07-06T10:00:10Z"]
      )
      _out, _code, emits = run_capture(dir, checks_json: json, session: "fake-sess")
      assert_equal %w[ci_test], emits.map { |e| e["event-slug"] },
                   "only a pass/fail verdict emits; pending/skipping/cancel are skipped"
    end
  end

  def test_normalizes_job_names_to_stable_ci_keys
    Dir.mktmpdir do |dir|
      json = checks(
        ["Scan Ruby", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:00:20Z"],
        ["CI / test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:00:20Z"]
      )
      _out, _code, emits = run_capture(dir, checks_json: json, session: "fake-sess")
      assert_equal %w[ci_scan_ruby ci_test], emits.map { |e| e["event-slug"] },
                   "names lower/underscore-normalize; a 'Workflow / job' prefix is stripped"
    end
  end

  # --- [unit] the guards mirror emit_test_scope EXACTLY ------------------------

  def test_is_a_no_op_when_no_session_is_present
    Dir.mktmpdir do |dir|
      json = checks(["test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:01:00Z"])
      out, code, emits = run_capture(dir, checks_json: json, session: "")
      assert_equal 0, code
      assert_empty emits, "no session ⇒ the session gate skips every emit"
    end
  end

  def test_never_fails_when_the_emit_seam_is_broken
    Dir.mktmpdir do |dir|
      json = checks(["test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:01:00Z"])
      _out, code, = run_capture(
        dir, checks_json: json, session: "fake-sess", agent_activity: File.join(dir, "does-not-exist")
      )
      assert_equal 0, code, "a broken emit target must not fail the ingest — it is best-effort"
    end
  end

  def test_never_fails_on_malformed_checks_json
    Dir.mktmpdir do |dir|
      _out, code, emits = run_capture(dir, checks_json: "not json at all", session: "fake-sess")
      assert_equal 0, code, "a bad read degrades to nothing-to-ingest, exit 0"
      assert_empty emits
    end
  end

  # --- [unit] idempotency key: stable across a re-read, distinct per sha -------

  def test_idempotency_key_is_stable_across_a_re_read_at_the_same_sha
    Dir.mktmpdir do |dir|
      json = checks(["test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:01:00Z"])
      _o1, _c1, first = run_capture(dir, checks_json: json, session: "fake-sess", head_sha: "sha-A")
      _o2, _c2, second = run_capture(dir, checks_json: json, session: "fake-sess", head_sha: "sha-A")
      assert_equal first.first["idempotency-key"], second.first["idempotency-key"],
                   "the same PR+sha+job re-read carries the SAME key (capture dedupes on it)"
      assert_equal "ci:123:sha-A:test", first.first["idempotency-key"]
    end
  end

  def test_idempotency_key_changes_with_the_head_sha
    Dir.mktmpdir do |dir|
      json = checks(["test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:01:00Z"])
      _o1, _c1, at_a = run_capture(dir, checks_json: json, session: "fake-sess", head_sha: "sha-A")
      _o2, _c2, at_b = run_capture(dir, checks_json: json, session: "fake-sess", head_sha: "sha-B")
      refute_equal at_a.first["idempotency-key"], at_b.first["idempotency-key"],
                   "a new sha is a new verdict — a distinct key"
    end
  end

  # --- [integration] a full PR fixture self-reports the right lanes ------------

  def test_end_to_end_ingest_of_a_full_pr_fixture_self_reports_every_verdict_lane
    Dir.mktmpdir do |dir|
      json = checks(
        ["scan_ruby", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:00:20Z"],
        ["scan_js", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:00:15Z"],
        ["lint", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:00:40Z"],
        ["test", "fail", "2026-07-06T10:00:00Z", "2026-07-06T10:06:00Z"]
      )
      out, code, emits = run_capture(dir, checks_json: json, session: "fake-sess", head_sha: "abc")
      assert_equal 0, code, out
      by_slug = emits.to_h { |e| [e["event-slug"], e["result-slug"]] }
      assert_equal "pass", by_slug["ci_scan_ruby"]
      assert_equal "pass", by_slug["ci_scan_js"]
      assert_equal "pass", by_slug["ci_lint"]
      assert_equal "fail", by_slug["ci_test"], "the failing CI job self-reports a fail verdict"
      assert(emits.all? { |e| e["kind"] == "test_scope" })
      assert(emits.all? { |e| e["idempotency-key"].start_with?("ci:123:abc:") })
    end
  end

  # --- [unit] the real GitHub workflow-run window rides on each emit -----------

  def test_forwards_the_real_workflow_run_start_and_completed_bounds
    Dir.mktmpdir do |dir|
      json = checks(["test", "pass", "2026-07-06T10:00:00Z", "2026-07-06T10:05:30Z"])
      _out, _code, emits = run_capture(dir, checks_json: json, session: "fake-sess")
      emit = emits.first
      assert_equal "2026-07-06T10:00:00Z", emit["started-at"],
                   "the job's real GitHub startedAt rides on the emit (ci_phase's real window start)"
      assert_equal "2026-07-06T10:05:30Z", emit["completed-at"],
                   "the job's real GitHub completedAt rides on the emit (the settle end)"
    end
  end

  def test_omits_the_real_bounds_when_a_stamp_is_missing
    Dir.mktmpdir do |dir|
      # A pass verdict with no start/complete stamps still self-reports its verdict,
      # but forwards NEITHER real bound — ci_phase then falls back to the approximation.
      json = checks(["test", "pass", "", ""])
      _out, _code, emits = run_capture(dir, checks_json: json, session: "fake-sess")
      emit = emits.first
      assert_equal "ci_test", emit["event-slug"], "the verdict still emits"
      refute emit.key?("started-at"), "a missing stamp forwards no partial real bound"
      refute emit.key?("completed-at"), "a missing stamp forwards no partial real bound"
    end
  end
end
