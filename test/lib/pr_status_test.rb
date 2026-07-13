require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../support/session_env"

# bin/pr-status runs `gh pr view` and prints a one-line health summary, with a
# loud hint when the PR is CONFLICTING (the case GitHub silently skips CI on).
# `gh` is stubbed via GH_BIN with a fake binary that echoes a canned JSON.
class PrStatusTest < Minitest::Test
  BIN = File.expand_path("../../bin/pr-status", __dir__)

  def run_with_gh(json, *args)
    Dir.mktmpdir do |dir|
      stub = File.join(dir, "gh")
      File.write(stub, "#!/bin/bash\ncat <<'JSON'\n#{json}\nJSON\n")
      File.chmod(0o755, stub)
      out, _err, status = Open3.capture3(SessionEnv.neutralized("GH_BIN" => stub), RbConfig.ruby, BIN, *args)
      [out, status]
    end
  end

  def test_mergeable_pr_prints_the_one_line_summary
    json = JSON.generate(
      "number" => 157, "state" => "OPEN", "mergeable" => "MERGEABLE",
      "mergeStateStatus" => "CLEAN", "isDraft" => false,
      "statusCheckRollup" => [{ "status" => "COMPLETED", "conclusion" => "SUCCESS" }]
    )
    out, status = run_with_gh(json, "157")

    assert status.success?
    assert_includes out, "#157 OPEN"
    assert_includes out, "mergeable=MERGEABLE"
    assert_includes out, "mergeState=CLEAN"
    assert_includes out, "ci=success"
    assert_includes out, "draft=false"
    refute_includes out, "CONFLICTING"
  end

  def test_conflicting_pr_prints_the_summary_plus_the_hint
    json = JSON.generate(
      "number" => 157, "state" => "OPEN", "mergeable" => "CONFLICTING",
      "mergeStateStatus" => "DIRTY", "isDraft" => false, "statusCheckRollup" => []
    )
    out, status = run_with_gh(json, "157")

    assert status.success?
    assert_includes out, "mergeState=DIRTY"
    assert_includes out, "ci=none", "no checks registered on an unmergeable PR"
    assert_includes out, "CONFLICTING — GitHub skips CI", "the diagnostic hint fires"
    assert_includes out, "merge origin/release"
  end
end
