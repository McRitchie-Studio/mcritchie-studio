require "test_helper"

# [unit] AgentSetupCheckJob: the hub's half of the check after Done.
class AgentSetupCheckJobTest < ActiveJob::TestCase
  APP_ID = "1560516264378507334".freeze

  def checking_setup
    setup = AgentSetup.open!(agent_slug: "mason", kind: "discord_bot", target: "mcritchie-studio", opened_by: "steffon",
                             details: { application_id: APP_ID })
    setup.submit!(by: "Alex McRitchie")
    setup
  end

  teardown { AgentMessages::DiscordBot.transport = nil }

  test "[unit] a bot in the server leaves the card waiting for Steffon" do
    setup = checking_setup
    AgentMessages::DiscordBot.transport = ->(*) { [ 200, JSON.generate("user" => { "id" => APP_ID }) ] }
    with_shared_token { AgentSetupCheckJob.perform_now(setup.id) }
    assert_equal "verifying", setup.reload.status
    assert_match(/Waiting for Steffon/, setup.status_reason)
  end

  test "[unit] a bot not in the server goes back to Alex McRitchie" do
    setup = checking_setup
    AgentMessages::DiscordBot.transport = ->(*) { [ 404, '{"message":"Unknown Member","code":10007}' ] }
    with_shared_token { AgentSetupCheckJob.perform_now(setup.id) }
    assert_equal "needs_attention", setup.reload.status
    assert_match(/use Invite/, setup.status_reason)
  end

  test "[unit] a Discord fault is recorded and the card says to press Done again" do
    setup = checking_setup
    AgentMessages::DiscordBot.transport = ->(*) { [ 502, "bad gateway" ] }
    assert_difference -> { ErrorLog.count }, 1 do
      with_shared_token { AgentSetupCheckJob.perform_now(setup.id) }
    end
    assert_equal "needs_attention", setup.reload.status
    assert_match(/Press Done to try again/, setup.status_reason)
  end

  test "[unit] a setup no longer checking is left alone" do
    setup = checking_setup
    setup.close!(by: "steffon")
    AgentSetupCheckJob.perform_now(setup.id)
    assert_equal "closed", setup.reload.status
    AgentSetupCheckJob.perform_now(0)
  end

  def with_shared_token
    old = ENV["DISCORD_AGENT_BOT_TOKEN"]
    ENV["DISCORD_AGENT_BOT_TOKEN"] = "shared-bot-token-for-tests"
    yield
  ensure
    old.nil? ? ENV.delete("DISCORD_AGENT_BOT_TOKEN") : ENV["DISCORD_AGENT_BOT_TOKEN"] = old
  end
end
