require "test_helper"

# [unit] Devops::DeployApprovalNotifier — the qa-chatter Discord nudge fired when a
# prod deploy enters the approval gate. Delivers via the DevOps progress webhook,
# is a no-op when unconfigured, and NEVER raises (logs to ErrorLog instead).
class Devops::DeployApprovalNotifierTest < ActiveSupport::TestCase
  setup do
    @prev = ENV["DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL"]
    ENV["DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL"] = "https://discord.test/qa-chatter"
    @run = GithubWorkflowRun.create!(
      repo: "mcritchie/mcritchie-studio", run_id: 321, status: "in_progress",
      workflow_name: "Production Deploy", head_sha: "abc1234def", head_branch: "release",
      pending_environment: "production", pending_since: 2.hours.ago
    )
  end

  teardown do
    if @prev.nil?
      ENV.delete("DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL")
    else
      ENV["DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL"] = @prev
    end
  end

  test "[unit] posts to the progress webhook with the run facts" do
    captured = {}
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content:, webhook_url:) { captured = { content: content, webhook_url: webhook_url }; true }) do
      assert Devops::DeployApprovalNotifier.notify_pending(@run)
    end

    assert_equal "https://discord.test/qa-chatter", captured[:webhook_url]
    assert_includes captured[:content], "awaiting approval"
    assert_includes captured[:content], "Production Deploy"
    assert_includes captured[:content], "production"
    assert_includes captured[:content], "/deployments"
    assert_includes captured[:content], "abc1234" # short sha
  end

  test "[unit] is a no-op (false) when no webhook is configured" do
    ENV.delete("DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL")
    ENV.delete("DISCORD_RELEASE_NOTES_WEBHOOK_URL")

    called = false
    ReleaseNotes::DiscordClient.stub(:deliver, ->(**) { called = true }) do
      assert_equal false, Devops::DeployApprovalNotifier.notify_pending(@run)
    end
    assert_not called, "must not attempt delivery without a webhook"
  end

  test "[unit] a nil run is a no-op" do
    assert_equal false, Devops::DeployApprovalNotifier.notify_pending(nil)
  end

  test "[unit] a delivery failure is captured to ErrorLog and never raised" do
    boom = ->(**) { raise ReleaseNotes::DiscordClient::DeliveryError, "discord down" }
    ReleaseNotes::DiscordClient.stub(:deliver, boom) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_nothing_raised do
          assert_equal false, Devops::DeployApprovalNotifier.notify_pending(@run)
        end
      end
    end
  end

  test "[unit] falls back to the release-notes webhook when the progress one is unset" do
    ENV.delete("DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL")
    ENV["DISCORD_RELEASE_NOTES_WEBHOOK_URL"] = "https://discord.test/release"

    captured = {}
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content:, webhook_url:) { captured[:url] = webhook_url; true }) do
      Devops::DeployApprovalNotifier.notify_pending(@run)
    end
    assert_equal "https://discord.test/release", captured[:url]
  ensure
    ENV.delete("DISCORD_RELEASE_NOTES_WEBHOOK_URL")
  end
end
