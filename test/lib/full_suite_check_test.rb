# frozen_string_literal: true

# Standalone test for bin/full-suite-check — the WRITE half of the full-suite gate
# (bin/dor-check is the READ half). It shells out to the script with the two lanes
# stubbed (FULL_SUITE_TEST_CMD / FULL_SUITE_RUBOCOP_CMD) so the orchestration is
# exercised without a real multi-minute `bin/rails test`. Run directly:
#   ruby -Itest test/lib/full_suite_check_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
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
  def run_check(dir, test_cmd:, rubocop_cmd:)
    env = {
      "FULL_SUITE_ROOT" => dir,
      "FULL_SUITE_TEST_CMD" => test_cmd,
      "FULL_SUITE_RUBOCOP_CMD" => rubocop_cmd
    }
    out = IO.popen(env, "#{BIN} --print 2>/dev/null", &:read)
    [out, $?.exitstatus]
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

  def test_no_fingerprint_outside_a_repo_exits_nonzero
    Dir.mktmpdir do |dir| # not a git repo
      out, code = run_check(dir, test_cmd: "true", rubocop_cmd: "true")
      assert_equal 1, code, out
      refute_match(/\[full-suite@/, out) # nothing certified without a fingerprint
    end
  end
end
