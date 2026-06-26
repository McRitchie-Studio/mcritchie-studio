require "test_helper"

class Release
  class SmokeSealTest < ActiveSupport::TestCase
    test "[unit] from_result builds a green seal when the smoke passed" do
      seal = SmokeSeal.from_result(passed: true, summary: "@qa-readonly green vs https://app.mcritchie.studio")

      assert seal.green?
      assert_not seal.red?
      assert_equal "green", seal.status
      assert_equal "🟢", seal.badge
      assert_equal "passed", seal.label
    end

    test "[unit] from_result builds a red seal when the smoke failed" do
      seal = SmokeSeal.from_result(passed: false, summary: "boom")

      assert seal.red?
      assert_not seal.green?
      assert_equal "red", seal.status
      assert_equal "🔴", seal.badge
      assert_equal "FAILED", seal.label
    end

    test "[unit] from_result stamps checked_at (defaults to now)" do
      freeze_time do
        assert_equal Time.now.utc.iso8601, SmokeSeal.from_result(passed: true).to_h["checked_at"]
      end
    end

    test "[unit] verdict_line folds badge + label + summary into one line" do
      green = SmokeSeal.from_result(passed: true, summary: "all good")
      assert_equal "🟢 Production smoke seal: passed — all good", green.verdict_line

      red = SmokeSeal.from_result(passed: false, summary: "2 specs failed")
      assert_equal "🔴 Production smoke seal: FAILED — 2 specs failed", red.verdict_line
    end

    test "[unit] verdict_line omits the dash when there is no summary" do
      assert_equal "🟢 Production smoke seal: passed", SmokeSeal.from_result(passed: true).verdict_line
    end

    test "[unit] to_h / from_h round-trips the verdict" do
      original = SmokeSeal.from_result(passed: false, summary: "down")
      rehydrated = SmokeSeal.from_h(original.to_h)

      assert_equal original, rehydrated
      assert rehydrated.red?
      assert_equal "down", rehydrated.summary
    end

    test "[unit] from_h tolerates symbol keys" do
      assert SmokeSeal.from_h(status: "green", summary: "ok").green?
    end

    test "[unit] from_h returns nil for an unsealed release (nil / empty hash / bad status)" do
      assert_nil SmokeSeal.from_h(nil)
      assert_nil SmokeSeal.from_h({})
      assert_nil SmokeSeal.from_h("status" => "purple")
      assert_nil SmokeSeal.from_h("not a hash")
    end

    test "[unit] from_h survives a malformed checked_at without raising" do
      seal = SmokeSeal.from_h("status" => "green", "checked_at" => "not-a-time")
      assert seal.green?
      assert_nil seal.checked_at
    end

    test "[unit] rollback_commands are empty on a green seal" do
      assert_empty SmokeSeal.from_result(passed: true).rollback_commands
    end

    test "[unit] rollback_commands surface the exact heroku/git/abandon recovery on red" do
      cmds = SmokeSeal.from_result(passed: false).rollback_commands(
        repo: "mcritchie-studio", heroku_app: "mcritchie-studio", deployed_sha: "abc1234"
      )

      assert_equal 3, cmds.size
      assert_includes cmds[0], "heroku rollback --app mcritchie-studio"
      assert_includes cmds[1], "git -C mcritchie-studio revert -m1 abc1234"
      assert_includes cmds[2], "Release#abandon!"
    end

    test "[unit] rollback_commands fall back to a placeholder SHA when none is known" do
      cmds = SmokeSeal.from_result(passed: false).rollback_commands(deployed_sha: nil)
      assert_includes cmds[1], "<release-merge-sha>"
    end
  end
end
