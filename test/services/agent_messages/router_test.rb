require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] AgentMessages::Router — guild + mention (bot user or role) + channel
# default decide the soul; anything else is unrouted.
class AgentMessages::RouterTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  def route(content, routes: agent_routes, channel: DESK, users: [], roles: [], guild: GUILD)
    AgentMessages::Router.new(routes).route(guild_id: guild, channel_id: channel, content: content,
                                            mention_users: users, mention_roles: roles)
  end

  test "a role mention routes to that role's soul (one shared bot with @Avi/@Xan roles)" do
    result = route("<@&#{XAN_ROLE}> what's on the board?", roles: [ XAN_ROLE ])
    assert_equal "xan", result.soul
    assert_equal "role", result.routed_by
  end

  test "a per-soul bot user mention routes to that soul, in both mention spellings" do
    assert_equal "avi", route("<@#{AVI_BOT}> status?", users: [ AVI_BOT ]).soul
    result = route("<@!#{AVI_BOT}> status?", users: [ AVI_BOT ])
    assert_equal [ "avi", "user" ], [ result.soul, result.routed_by ]
  end

  test "two souls mentioned: the one written first wins, and the other is named" do
    result = route("<@&#{XAN_ROLE}> and <@&#{AVI_ROLE}> please", roles: [ AVI_ROLE, XAN_ROLE ])
    assert_equal "xan", result.soul
    assert_equal [ "avi" ], result.detail["also_mentioned"]
  end

  test "a mention Discord lists without one in the text still routes, users before roles" do
    assert_equal "avi", route("thanks!", users: [ AVI_BOT ], roles: [ XAN_ROLE ]).soul
  end

  test "no mention falls to the channel default soul" do
    result = route("anyone around?", routes: agent_routes(default_soul: "avi"))
    assert_equal [ "avi", "default" ], [ result.soul, result.routed_by ]
  end

  test "no mention and no default is unrouted, with the reason" do
    result = route("anyone around?")
    assert_nil result.soul
    assert_equal "none", result.routed_by
    refute result.routed?
    assert_match(/no routed soul/, result.detail["reason"])
  end

  test "an id from another guild, or a mention of an unmapped user, routes nowhere" do
    assert_nil route("<@&#{AVI_ROLE}> hi", roles: [ AVI_ROLE ], guild: "123").soul
    assert_nil route("<@#{SHARED_BOT}> hi", users: [ SHARED_BOT ]).soul
  end

  test "the shipped config loads, lists no channel yet, and so polls nothing" do
    routes = AgentMessages::Routes.load
    assert_equal [], routes.channels
  end

  test "routes read every id as a string and list the routable souls" do
    routes = agent_routes(default_soul: "avi")
    assert_equal [ DESK, QUIET ], routes.channels.map(&:channel_id)
    assert_equal %w[avi xan], routes.souls.sort
    assert_equal "avi", routes.mention_map(GUILD)["role"][AVI_ROLE]
  end
end
