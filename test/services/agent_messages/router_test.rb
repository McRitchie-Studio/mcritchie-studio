require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] AgentMessages::Router and AgentMessages::Routes — the guild is the
# boundary; a mention (bot user or role) or a channel override's default decides
# the soul; anything else is unrouted (and DiscordIngest drops it).
class AgentMessages::RouterTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  def route(content, routes: agent_routes, channel: DESK, users: [], roles: [], guild: GUILD, parent: nil)
    AgentMessages::Router.new(routes).route(guild_id: guild, channel_id: channel, content: content,
                                            mention_users: users, mention_roles: roles, parent_id: parent)
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

  test "a thread takes its parent channel's default unless it has its own override" do
    routes = agent_routes(default_soul: "avi")
    assert_equal "avi", route("anyone?", routes: routes, channel: DESK_THREAD, parent: DESK).soul
    assert_nil route("anyone?", routes: routes, channel: DESK_THREAD).soul, "an unknown parent inherits nothing"
    assert_nil route("anyone?", routes: routes, channel: LOUNGE).soul
  end

  test "the shipped config lists the McRitchie Studio guild with no channel entries and routes @Xan anywhere in it" do
    routes = AgentMessages::Routes.load
    xan = "1481150857809760399"
    studio = "1332466565203103744"
    tank = "1479973077021495478"
    assert_equal [ studio ], routes.guild_ids
    assert_empty routes.overrides, "the guild is the boundary; no channel needs an entry"
    assert_equal xan, routes.bot_user_id

    [ tank, "1332466565203103747", "999999999999999999" ].each do |channel|
      mentioned = route("<@#{xan}> what is building?", routes: routes, guild: studio, channel: channel, users: [ xan ])
      assert_equal [ "xan", "user" ], [ mentioned.soul, mentioned.routed_by ], "channel #{channel}"
    end
    assert_nil route("anyone around?", routes: routes, guild: studio, channel: tank).soul
    refute routes.guild?("123"), "a guild that is not listed is out of scope"
  end

  test "routes read every id as a string, list overrides and the routable souls" do
    routes = agent_routes(default_soul: "avi")
    assert_equal [ GUILD ], routes.guild_ids
    assert_equal [ DESK, MUTED ], routes.overrides.map(&:channel_id)
    assert routes.ignored?(GUILD, MUTED)
    assert routes.ignored?(GUILD, DESK_THREAD, parent_id: MUTED), "a thread under a muted channel is muted"
    refute routes.ignored?(GUILD, DESK)
    refute routes.ignored?(GUILD, LOUNGE)
    assert_equal "avi", routes.default_soul(GUILD, DESK)
    assert_nil agent_routes.default_soul(GUILD, DESK), "an empty default_soul is none"
    assert_equal %w[avi xan], routes.souls.sort
    assert_equal "avi", routes.mention_map(GUILD)["role"][AVI_ROLE]
  end
end
