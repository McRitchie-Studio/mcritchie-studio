require "test_helper"

# [unit] AgentSetups::Command, the dyno half of bin/agent-setup: open a card,
# list, and take verify's report, re-checking an installed token from this
# process's own environment before a card turns ready. No secret is ever taken
# or answered.
class AgentSetups::CommandTest < ActiveSupport::TestCase
  APP_ID = "1560516264378507334".freeze
  TOKEN = "MTU2MDUxNjI2NDM3ODUwNzMzNA.GxYzAb.installedinstalledinstalledinstalled".freeze

  def call(request) = AgentSetups::Command.call(request)

  def open_mason
    call("verb" => "open", "kind" => "discord_bot", "soul" => "mason", "by" => "steffon",
         "details" => { "op_item_id" => "c" * 26, "op_vault_id" => "b" * 26, "op_account_id" => "a" * 26,
                        "op_host" => "my.1password.com", "secret_env" => "IGNORED" })
  end

  def waiting_setup
    setup = AgentSetup.find(open_mason["id"])
    setup.update!(details: setup.details.merge("application_id" => APP_ID))
    setup.submit!(by: "Alex McRitchie")
    setup.await_verify!("Waiting for Steffon.")
    setup
  end

  teardown do
    AgentMessages::DiscordBot.transport = nil
    ENV.delete("DISCORD_BOT_TOKEN_MASON")
  end

  test "[unit] open makes the card with the kit's details; the CLI cannot override what the kit decides" do
    answer = open_mason
    assert_equal "pending", answer["status"]
    assert_equal "DISCORD_BOT_TOKEN_MASON", answer["secret_env"], "secret_env is the kit's, not the caller's"
    assert answer["op_link"]
    assert_equal 5, answer["steps"].size
    assert_match(/already open/, open_mason["error"])
    assert_match(/no agent "ghost"/, call("verb" => "open", "kind" => "discord_bot", "soul" => "ghost", "by" => "s")["error"])
    assert_match(/--by/, call("verb" => "open", "kind" => "discord_bot", "soul" => "mack")["error"])
  end

  test "[unit] list answers the open cards and the finished ones" do
    open_mason
    assert_equal [ "mason" ], call("verb" => "list")["open"].map { |s| s["soul"] }
  end

  test "[unit] a failed verify puts the card back to Alex McRitchie with the reason" do
    setup = waiting_setup
    answer = call("verb" => "report", "id" => setup.id, "by" => "steffon", "ok" => false,
                  "reason" => "The bot is not in the server yet.", "bot_user_id" => APP_ID)
    assert_equal "needs_attention", answer["status"]
    assert_equal "Steffon's verify: The bot is not in the server yet.", answer["status_reason"]
    assert_equal APP_ID, setup.reload.detail(:bot_user_id)
  end

  test "[unit] a verified token not yet installed stays waiting for Steffon" do
    setup = waiting_setup
    answer = call("verb" => "report", "id" => setup.id, "by" => "steffon", "ok" => true, "installed" => false)
    assert_equal "verifying", answer["status"]
    assert_match(/not installed yet/, answer["status_reason"])
  end

  test "[unit] an installed token is re-checked from this environment before the card turns ready" do
    setup = waiting_setup
    ENV["DISCORD_BOT_TOKEN_MASON"] = TOKEN
    seen = nil
    AgentMessages::DiscordBot.transport = lambda do |method, url, headers, _body|
      seen = [ method, url, headers["Authorization"] ]
      [ 200, JSON.generate("id" => APP_ID, "bot" => true, "username" => "Mason") ]
    end
    answer = call("verb" => "report", "id" => setup.id, "by" => "steffon", "ok" => true, "installed" => true)
    assert_equal "ready", answer["status"]
    assert_equal [ :get, "https://discord.com/api/v10/users/@me", "Bot #{TOKEN}" ], seen
    refute_includes JSON.generate(answer), TOKEN
    assert_equal "steffon", setup.reload.verified_by
    assert setup.ready_at
  end

  test "[unit] an install this environment cannot see, or Discord refuses, is not ready" do
    setup = waiting_setup
    answer = call("verb" => "report", "id" => setup.id, "by" => "steffon", "ok" => true, "installed" => true)
    assert_equal "needs_attention", answer["status"]
    assert_match(/does not see it/, answer["status_reason"])

    ENV["DISCORD_BOT_TOKEN_MASON"] = TOKEN
    AgentMessages::DiscordBot.transport = ->(*) { [ 401, '{"message":"401: Unauthorized"}' ] }
    answer = call("verb" => "report", "id" => setup.id, "by" => "steffon", "ok" => true, "installed" => true)
    assert_equal "needs_attention", answer["status"]
    assert_match(/The installed DISCORD_BOT_TOKEN_MASON: Discord refused the token \(401\)/, answer["status_reason"])
  end

  test "[unit] report refuses a card still on Alex McRitchie's turn; close finishes one" do
    id = open_mason["id"]
    assert_match(/is pending/, call("verb" => "report", "id" => id, "by" => "steffon", "ok" => true)["error"])
    assert_equal "closed", call("verb" => "close", "id" => id, "by" => "steffon")["status"]
    assert_match(/unknown verb/, call("verb" => "explode")["error"])
  end
end
