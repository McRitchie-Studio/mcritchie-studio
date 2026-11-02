# frozen_string_literal: true

# [unit] bin/dor-check --precheck: the merge gate's rules minus its CI read, asked by bin/submit
# at 0/8 before it commits or pushes (/tasks/submit-checks-before-push). What it must hold:
#   * it refuses what 7/8 would refuse on metadata and tiers;
#   * it never reads CI: a RED injected CI does not refuse it, because 7/8 owns that;
#   * it records no GateRun, and it names itself in every line, so its pass is not the verdict;
#   * it is the builder's merge gate only: review's gate-zero exists to read CI.
# History: task submit-checks-before-push.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class DorCheckPrecheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/7"
  CODE_DIFF = "app/models/thing.rb"

  def devops(overrides = {})
    {
      "kind" => "feature", "shape" => "backend", "pr_url" => PR_URL,
      "acceptance" => ["Things persist"], "repositories" => ["myapp"], "risk_tags" => ["low"],
      "test_plan" => ["[unit] thing_test", "[integration] things flow"],
      "checks_run" => ["[unit] bin/rails test test/models/thing_test.rb",
                       "[integration] bin/rails test test/integration/things_test.rb"],
      "post_deploy_cmd" => "none"
    }.merge(overrides)
  end

  # [output, exit code, gate-stub calls]. STDOUT only: rubygems warnings ride STDERR.
  def check(payload, ci: nil, args: "--precheck", changed: CODE_DIFF)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "pre-task", "title" => "T", "metadata" => { "devops" => payload }))
      gate_log = File.join(dir, "gate-calls.log")
      gate_bin = File.join(dir, "gate-stub")
      File.write(gate_bin, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"#{gate_log}\"\n")
      FileUtils.chmod(0o755, gate_bin)
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => changed, "DOR_CHECK_PR_FILES" => changed,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_GATE_BIN" => gate_bin
      }.compact)
      out = IO.popen(env, "#{BIN} pre-task --file #{path} #{args} 2>/dev/null", &:read)
      code = $?.exitstatus
      [out, code, File.exist?(gate_log) ? File.readlines(gate_log, chomp: true) : []]
    end
  end

  def test_a_missing_tier_refuses_before_any_ci_exists
    out, code, = check(devops("checks_run" => ["[unit] bin/rails test test/models/thing_test.rb"]))

    assert_equal 1, code, out
    assert_includes out, "✗ DoR pre-check NOT met"
    assert_includes out, "missing test tiers"
    assert_includes out, "- integration"
  end

  def test_missing_metadata_refuses
    out, code, = check(devops("acceptance" => []))

    assert_equal 1, code, out
    assert_includes out, "devops.acceptance"
  end

  # The pre-check drops the CI read and nothing else: a RED CI cannot refuse it, and
  # the same task the full gate refuses on that CI passes here.
  def test_a_red_ci_does_not_refuse_the_pre_check_but_does_refuse_the_full_gate
    out, code, = check(devops, ci: "red")
    assert_equal 0, code, out
    assert_includes out, "✓ DoR pre-check met"

    full_out, full_code, = check(devops, ci: "red", args: "")
    assert_equal 1, full_code, "control: the full merge gate refuses this CI:\n#{full_out}"
  end

  def test_the_pass_line_says_ci_was_not_read_and_the_verdict_comes_later
    out, code, = check(devops)

    assert_equal 0, code, out
    assert_includes out, "CI NOT read"
    assert_includes out, "bin/submit 7/8"
    refute_includes out, "DoR-to-Merge met", "a pre-check pass must never read as the verdict"
  end

  # A pre-check is not an attempt. The full gate, same fixture, records one — the
  # control that proves the stub would have seen a write.
  def test_the_pre_check_records_no_gate_run
    _out, _code, calls = check(devops)
    assert_empty calls, "the pre-check wrote a GateRun: #{calls.inspect}"

    _out, _code, full_calls = check(devops, ci: "green", args: "")
    refute_empty full_calls, "control: the full gate records its attempt"
  end

  def test_review_role_and_the_build_gate_refuse_the_flag
    out, code, = check(devops, args: "--precheck --gate-role review")
    assert_equal 1, code, out

    out, code, = check(devops, args: "--precheck --gate build")
    assert_equal 1, code, out
  end

  # A non-code kind's exempt path also reads CI; the pre-check skips it there too.
  def test_an_exempt_doc_diff_passes_without_reading_ci
    out, code, = check(devops("kind" => "docs", "shape" => nil).compact, ci: "red",
                       changed: "docs/agents/modules/deployment.md")

    assert_equal 0, code, out
    refute_includes out, "RED"

    full_out, full_code, = check(devops("kind" => "docs", "shape" => nil).compact, ci: "red", args: "",
                                 changed: "docs/agents/modules/deployment.md")
    assert_equal 1, full_code, "control: the full gate reads CI on an exempt diff and refuses red:\n#{full_out}"
  end
end
