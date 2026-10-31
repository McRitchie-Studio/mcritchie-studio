require "test_helper"
require_relative "../../support/teams_fixtures"

# [unit] The `teams:` block (AgentMessages::TeamsRoutes): the addressing,
# clearance, recognized names and core_souls are ChannelRoutes', shared with
# Slack, so the same text routes the same way on both; the shipped block names
# the same souls as Slack's; the tenant and app id read their ENV first; the
# bot's own account is recognized.
class AgentMessagesTeamsRoutesTest < ActiveSupport::TestCase
  include TeamsFixtures

  test "[unit] the shipped teams block serves the same souls, names, recognized names and core souls as slack" do
    yaml = YAML.safe_load_file(AgentMessages::ChannelRoutes::PATH, aliases: false)
    teams = AgentMessages::TeamsRoutes.new(yaml["teams"])
    slack = AgentMessages::SlackRoutes.new(yaml["slack"])

    assert_equal slack.souls, teams.souls
    assert_equal slack.recognized, teams.recognized
    assert_equal slack.core_souls, teams.core_souls
    assert_equal slack.mention_soul, teams.mention_soul
    assert_empty teams.channels, "no channels until teams-app-kit creates them"
    assert_nil teams.owner_aad_object_id, "empty until the tenant exists"
  end

  test "[unit] SlackRoutes and TeamsRoutes are both ChannelRoutes and read the same text the same way" do
    slack = AgentMessages::SlackRoutes.new("souls" => teams_routes.souls.transform_values { |n| { "names" => n } }, "recognized" => { "hank" => { "names" => [ "Hank" ] } })
    teams = teams_routes
    assert_kind_of AgentMessages::ChannelRoutes, slack
    assert_kind_of AgentMessages::ChannelRoutes, teams

    [ "Avi, what shipped?", "Avi and Mason, status?", "@Avi @Mason look", "Avi and Mason are right",
      "Hi Alex, quick one", "Hank, the weld", "Everyone, standup" ].each do |text|
      assert_equal slack.addressed(text), teams.addressed(text), text
      assert_equal slack.everyone?(text), teams.everyone?(text), text
    end
    refute teams.everyone?("<!channel> hi"), "Slack's broadcast markup is Slack's alone"
  end

  test "[unit] clearance and the unanswerable reason name the teams block" do
    routes = teams_routes(channels: { CHANNEL => { "name" => "turf-monster", "souls" => [ "turf_monster" ] } })

    assert routes.cleared?(CHANNEL, "avi"), "a core soul"
    assert routes.cleared?(CHANNEL, "turf_monster")
    refute routes.cleared?(CHANNEL, "tyrion")
    assert routes.cleared?("19:other@thread.tacv2", "tyrion"), "a channel with no clearance config admits every soul"
    assert_includes routes.clearance_reason(CHANNEL, "tyrion"), "(config/agent_routes.yml teams.channels)"
    assert_includes routes.unanswerable_reason("hank"), "on Teams"
    assert_includes routes.unanswerable_reason("hank"), "teams.recognized"
    refute routes.answers?("hank")
  end

  test "[unit] the tenant and the app id read TEAMS_TENANT_ID and TEAMS_BOT_APP_ID first; the bot's account is 28:<app id>" do
    routes = teams_routes
    with_env("TEAMS_TENANT_ID", nil) do
      with_env("TEAMS_BOT_APP_ID", nil) do
        assert routes.tenant?(TENANT.upcase), "tenant ids compare case-insensitively"
        refute routes.tenant?("another")
        assert_equal APP_ID, routes.bot_app_id
      end
    end
    with_env("TEAMS_TENANT_ID", "env-tenant") do
      with_env("TEAMS_BOT_APP_ID", "env-app") do
        assert routes.tenant?("env-tenant")
        assert routes.bot?("28:env-app")
      end
    end
    refute AgentMessages::TeamsRoutes.new({}).tenant?(""), "no tenant configured reads nothing"
    assert routes.bot?("28:#{APP_ID}")
    refute routes.bot?("29:a-person")
  end
end
