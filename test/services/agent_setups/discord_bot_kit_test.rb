require "test_helper"

# [unit] AgentSetups::DiscordBotKit: the invite carries the seat's permissions,
# the 1Password deep link is built only from well-formed ids, and the hub's
# check maps what the shared bot sees to verifying or a reason.
class AgentSetups::DiscordBotKitTest < ActiveSupport::TestCase
  APP_ID = "1560516264378507334".freeze
  KIT = AgentSetups::DiscordBotKit

  def setup_for(soul, **details)
    Agent.find_or_create_by!(slug: soul) { |a| a.name = soul.titleize }
    AgentSetup.open!(agent_slug: soul, kind: "discord_bot", target: "mcritchie-studio", opened_by: "steffon", details: details)
  end

  test "[unit] the invite URL carries the seat's permissions: reply, a CTO's embeds, Steffon's server admin" do
    assert_equal 274_877_975_552, KIT.permissions_for("reply")
    assert_equal 274_877_991_936, KIT.permissions_for("cto")
    assert_equal "server_admin", KIT.permission_set_for("steffon")
    assert_equal "cto", KIT.permission_set_for("avi"), "config/cto_reports.yml names Avi a CTO"
    assert_equal "reply", KIT.permission_set_for("mack")
    assert_equal "reply", KIT.permission_set_for("ray"), "a soul with no seat and no CTO report replies"

    url = KIT.invite_url(setup_for("steffon", application_id: APP_ID))
    query = Rack::Utils.parse_query(URI(url).query)
    assert url.start_with?("https://discord.com/oauth2/authorize?")
    assert_includes url, "scope=bot%20applications.commands"
    assert_equal APP_ID, query["client_id"]
    assert_equal (274_877_991_936 + 16 + (1 << 28) + (1 << 29)).to_s, query["permissions"]
    assert_equal "1332466565203103744", query["guild_id"]
  end

  # The integers the SOP quotes (agent-onboarding.md, discord-bot-setup.md):
  # a drift in config/agent_setups.yml fails here, not on Alex McRitchie's invite.
  test "[unit] the five bots' seats and the integers the SOP quotes" do
    assert_equal 274_877_975_552, KIT.permissions_for("reply")
    assert_equal 274_877_991_936, KIT.permissions_for("cto")
    assert_equal 275_683_298_320, KIT.permissions_for("server_admin")
    assert_equal({ "alex" => "cto", "mason" => "cto", "mack" => "reply", "steffon" => "server_admin", "turf_monster" => "cto" },
                 %w[alex mason mack steffon turf_monster].index_with { |soul| KIT.permission_set_for(soul) })
    refute KIT.config.fetch("seats").key?("tyrion"), "Tyrion's token lives in OpenClaw: no seat, no card"
  end

  test "[unit] a new card points at discord.<soul>.agents, and only the shared bot's soul installs DISCORD_AGENT_BOT_TOKEN too" do
    alex = KIT.default_details("alex")
    assert_equal "discord.alex.agents", alex["op_item"]
    assert_equal "DISCORD_BOT_TOKEN_ALEX", alex["secret_env"]
    assert_equal "DISCORD_AGENT_BOT_TOKEN", alex["also_env"]
    assert_equal AgentMessages::DiscordBot::TOKEN_ENV, alex["also_env"], "the var the shared reader actually reads"

    %w[mason mack steffon turf_monster].each do |soul|
      details = KIT.default_details(soul)
      assert_equal "discord.#{soul}.agents", details["op_item"]
      assert_equal AgentMessages::DiscordBot.soul_token_env(soul), details["secret_env"]
      refute details.key?("also_env"), "#{soul} is not the shared bot"
    end
  end

  test "[unit] no invite until the application id is a snowflake" do
    assert_nil KIT.invite_url(setup_for("mason"))
    assert_nil KIT.invite_url(setup_for("avi", application_id: "not-an-id"))
  end

  # The ids in the shape 1Password issues them (synthetic values): the account
  # id uppercase, as `op whoami` answers account_uuid; vault and item lowercase.
  OP_ACCOUNT = "QZ7XK2MNB4RTY8WVPL3HJD6CFA".freeze
  OP_VAULT = "k3v9m2qx7tpl4wz8ndr6hyb5ce".freeze
  OP_ITEM = "w8jn5rc2xh7bq4mt9plz3dfk6y".freeze
  OP_IDS = { op_account_id: OP_ACCOUNT, op_vault_id: OP_VAULT, op_item_id: OP_ITEM, op_host: "my.1password.com" }.freeze

  test "[unit] op_link builds with an uppercase account id and lowercase vault and item ids" do
    link = KIT.op_link(setup_for("mason", **OP_IDS))
    assert_equal "https://start.1password.com/open/i?a=#{OP_ACCOUNT}&v=#{OP_VAULT}&i=#{OP_ITEM}&h=my.1password.com", link
    assert KIT.op_link(setup_for("mack", **OP_IDS, op_host: "mcritchie.1password.ca")), "a team host on another region"
  end

  test "[unit] op_link refuses wrong lengths, other characters, the wrong case and a foreign host" do
    refusals = {
      "account one short" => { op_account_id: OP_ACCOUNT[0..-2] },
      "account one long" => { op_account_id: "#{OP_ACCOUNT}A" },
      "account lowercase (a vault id in the account slot)" => { op_account_id: OP_VAULT },
      "account with a dash" => { op_account_id: "#{OP_ACCOUNT[0..-2]}-" },
      "vault uppercase (the account id in the vault slot)" => { op_vault_id: OP_ACCOUNT },
      "vault one short" => { op_vault_id: OP_VAULT[0..-2] },
      "item short" => { op_item_id: "short" },
      "item with a slash" => { op_item_id: "#{OP_ITEM[0..-2]}/" },
      "item with a newline" => { op_item_id: "#{OP_ITEM}\n" },
      "no account" => { op_account_id: nil },
      "foreign host" => { op_host: "evil.example.com" },
      "look-alike host" => { op_host: "my.1password.com.evil.example" }
    }
    assert KIT.op_link(AgentSetup.new(details: OP_IDS.stringify_keys)), "the unsaved control builds"
    refusals.each do |why, bad|
      assert_nil KIT.op_link(AgentSetup.new(details: OP_IDS.merge(bad).compact.stringify_keys)), why
    end
  end

  class FakeDiscord
    def initialize(&answer) = @answer = answer
    def guild_member(guild, user) = @answer.call(guild, user)
  end

  test "[unit] the hub check: a member waits for Steffon; a missing member goes back to Alex McRitchie" do
    setup = setup_for("mason", application_id: APP_ID)
    asked = nil
    verdict, note = KIT.hub_check(setup, discord: FakeDiscord.new { |g, u| asked = [ g, u ]; { "user" => { "id" => u } } })
    assert_equal :verifying, verdict
    assert_equal [ "1332466565203103744", APP_ID ], asked
    assert_match(/in McRitchie Studio\. Waiting for Steffon to verify .* DISCORD_BOT_TOKEN_MASON/, note)

    missing = FakeDiscord.new { raise AgentMessages::DiscordBot::Error, "Discord refused to read member: HTTP 404 Unknown Member" }
    verdict, reason = KIT.hub_check(setup, discord: missing)
    assert_equal :needs_attention, verdict
    assert_match(/not in McRitchie Studio yet: use Invite/, reason)

    refused = FakeDiscord.new { raise AgentMessages::DiscordBot::Unauthorized, "HTTP 403" }
    assert_equal :verifying, KIT.hub_check(setup, discord: refused).first

    broken = FakeDiscord.new { raise AgentMessages::DiscordBot::Error, "HTTP 502" }
    assert_raises(AgentMessages::DiscordBot::Error) { KIT.hub_check(setup, discord: broken) }
  end

  test "[unit] the hub check without a shared bot token says so and still waits for Steffon" do
    setup = setup_for("mason", application_id: APP_ID)
    with_env("DISCORD_AGENT_BOT_TOKEN" => nil) do
      verdict, note = KIT.hub_check(setup)
      assert_equal :verifying, verdict
      assert_match(/could not check the server/, note)
    end
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
