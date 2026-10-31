require "test_helper"
require_relative "../../support/agent_message_fixtures"
require_relative "../../support/teams_fixtures"

# [unit] AgentMessages::TeamsIngest: one Teams message activity becomes one
# AgentMessage per soul it is for, once (dedupe on channel + activity id); the
# bot's own <at> mention is stripped before routing; bot-authored activities,
# another tenant's, and every type but message are dropped; the thread key is
# the channel thread's root; routing, clearance and fan-out are Slack's, shared;
# the owner is linked by Entra object id; install events record conversation
# references.
class AgentMessagesTeamsIngestTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include TeamsFixtures

  def ingest(routes = teams_routes, answerers: AgentMessages::Answerers.current)
    AgentMessages::TeamsIngest.new(routes: routes, answerers: answerers)
  end

  test "[unit] a channel message to Avi is stored once with the thread root, the reference a reply needs, and the person" do
    row = ingest.call(teams_activity(text: "Avi, what shipped?", id: "1761900000001"))

    assert_equal [ "teams", "#{CHANNEL}:1761900000001", "avi", "name", "received" ],
                 [ row.channel, row.external_id, row.soul_slug, row.routed_by, row.status ]
    assert_equal [ TENANT, CHANNEL, "teams:#{CHANNEL}:1761900000001" ], [ row.guild_id, row.channel_ref, row.thread_key ]
    assert_equal "Avi, what shipped?", row.content
    assert_equal "Pat Member", row.author_name
    env = row.envelope
    assert_equal [ SERVICE_URL, "#{CHANNEL};messageid=1761900000001", "1761900000001", "channel", TEAM ],
                 env.values_at("service_url", "conversation_id", "activity_id", "conversation_type", "team_id")
    assert_equal "teams", row.person.identities.sole.platform
    assert_equal %w[received routed], row.events.order(:id).pluck(:kind)
    assert_equal "teams-events", row.events.order(:id).first.actor

    assert_no_difference -> { AgentMessage.count } do
      assert_equal row, ingest.call(teams_activity(text: "Avi, what shipped?", id: "1761900000001")), "a retried delivery"
    end
    assert TeamsConversation.installed.exists?(conversation_id: CHANNEL), "a message refreshes the reference"
  end

  test "[unit] the same activity id in another channel is another message (dedupe is per channel + id)" do
    ingest.call(teams_activity(id: "42"))
    other = ingest.call(teams_activity(id: "42", channel: "19:other0000000000000000000000000@thread.tacv2"))

    assert other
    assert_equal 2, AgentMessage.where(channel: "teams").count
  end

  test "[unit] the bot's own <at> mention is stripped before routing; a bare mention goes to the mention soul" do
    named = ingest.call(teams_activity(text: "Avi, is QA green?", id: "1", mention_bot: true))
    assert_equal [ "avi", "name", "Avi, is QA green?" ], [ named.soul_slug, named.routed_by, named.content ]

    bare = ingest.call(teams_activity(text: "what is on today?", id: "2", mention_bot: true))
    assert_equal [ "alex", "mention" ], [ bare.soul_slug, bare.routed_by ]
    assert_equal({ "matched" => "app mention", "soul" => "alex", "routed_by" => "mention" },
                 bare.events.find_by(kind: "routed").detail)
  end

  test "[unit] another person's <at> mention is kept as @Name, and HTML a formatted message carries is reduced to text" do
    act = teams_activity(text: "<p><at>Avi</at> look at <b>this</b> &amp; that</p>", id: "3")
    act["entities"] = [ { "type" => "mention", "text" => "<at>Avi</at>", "mentioned" => { "id" => "29:avi-person", "name" => "Avi" } } ]
    row = ingest.call(act)

    assert_equal "@Avi look at this & that", row.content
    assert_equal "avi", row.soul_slug, "@Avi opens the message"
    assert_equal [ "29:avi-person" ], row.mentions["users"]
  end

  test "[unit] bot-authored activities, other tenants, unconfigured tenants and non-message types are never stored" do
    bot = teams_activity(id: "b1")
    bot["from"] = { "id" => "28:#{APP_ID}", "name" => "McRitchie Agents", "aadObjectId" => "x" }
    other_bot = teams_activity(id: "b2")
    other_bot["from"] = { "id" => "28:another-bot", "aadObjectId" => "y", "role" => "bot" }
    other_tenant = teams_activity(id: "t1")
    other_tenant["channelData"]["tenant"]["id"] = "someone-else"
    other_tenant["conversation"]["tenantId"] = "someone-else"
    edit = teams_activity(id: "e1").merge("type" => "messageUpdate")
    not_teams = teams_activity(id: "w1").merge("channelId" => "webchat")

    assert_no_difference -> { AgentMessage.count } do
      [ bot, other_bot, other_tenant, edit, not_teams, teams_activity(id: "x1", text: "  ") ].each { |a| assert_nil ingest.call(a) }
      assert_nil ingest(AgentMessages::TeamsRoutes.new({})).call(teams_activity(id: "n1")), "no tenant configured"
    end
  end

  test "[unit] a reply in a channel thread keeps the thread's soul; the thread key is the root's" do
    root = ingest.call(teams_activity(text: "Mason, the release?", id: "100"))
    reply = ingest.call(teams_activity(text: "and the hub?", id: "101", root: "100"))

    assert_equal "teams:#{CHANNEL}:100", reply.thread_key
    assert_equal [ "mason", "thread" ], [ reply.soul_slug, reply.routed_by ]
    assert_equal root.thread_key, reply.thread_key
  end

  test "[unit] several souls named fan out, one row each, in one thread, sharing envelope.fan" do
    primary = ingest.call(teams_activity(text: "Avi and Mason, status?", id: "200"))
    rows = AgentMessage.where(channel: "teams").order(:id)

    assert_equal %w[avi mason], rows.map(&:soul_slug)
    assert_equal [ "#{CHANNEL}:200", "#{CHANNEL}:mason:200" ], rows.map(&:external_id)
    assert_equal [ primary.external_id ] * 2, rows.map { |r| r.envelope["fan"] }
    assert_equal [ "200" ] * 2, rows.map { |r| r.envelope["activity_id"] }, "each sibling replies to the one activity"
    assert_equal 1, rows.map(&:thread_key).uniq.size
  end

  test "[unit] everyone fans to every served soul cleared in the channel" do
    routes = teams_routes(channels: { CHANNEL => { "name" => "turf-monster", "souls" => [ "turf_monster" ] } })
    ingest(routes).call(teams_activity(text: "Everyone, standup", id: "300"))

    assert_equal %w[alex avi mason turf_monster], AgentMessage.where(channel: "teams").pluck(:soul_slug).sort
  end

  test "[unit] clearance holds a soul not cleared in the channel, and a recognized-only soul is held as unanswerable" do
    routes = teams_routes(channels: { CHANNEL => { "name" => "cyvasse", "souls" => [] } })
    held = ingest(routes).call(teams_activity(text: "Turf, scores?", id: "400"))
    hank = ingest(routes).call(teams_activity(text: "Hank, the weld?", id: "401"))

    assert_equal [ "turf_monster", "held" ], [ held.soul_slug, held.status ]
    event = held.events.find_by(kind: "held")
    assert_equal "teams-clearance", event.actor
    assert_includes event.detail["reason"], "teams.channels"
    assert_equal "held", hank.status
    assert_includes hank.events.find_by(kind: "held").detail["reason"], "soul cannot answer yet"
  end

  test "[unit] the owner-only guard: the owner's Entra object id is linked by seed_owner!, so his messages are answered" do
    AgentMessages::Answerers.reset!
    AgentMessages::TeamsRoutes.current = teams_routes
    owner = AgentPerson.seed_owner!
    answerers = AgentMessages::Answerers.current

    mine = ingest(answerers: answerers).call(teams_activity(text: "Avi, hi", id: "500", from_aad: OWNER_AAD))
    theirs = ingest(answerers: answerers).call(teams_activity(text: "Avi, hi", id: "501"))

    assert_equal [ owner.id, "received" ], [ mine.person_id, mine.status ]
    assert_equal "held", theirs.status
  ensure
    AgentMessages::TeamsRoutes.reset!
  end

  test "[unit] a personal chat with the bot goes to the mention soul and is private" do
    row = ingest.call(teams_activity(text: "hello there", id: "600", channel: "a:personal-chat-1", conversation_type: "personal"))

    assert_equal [ "alex", "mention", "a:personal-chat-1", "teams:a:personal-chat-1:600" ],
                 [ row.soul_slug, row.routed_by, row.channel_ref, row.thread_key ]
    assert_equal({ "matched" => "direct message", "soul" => "alex", "routed_by" => "mention" }, row.events.find_by(kind: "routed").detail)
    assert AgentMessages::MemoryBundle.new(row).send(:private_channel?)
  end

  test "[unit] the install conversationUpdate stores a conversation reference; removal marks it removed; channelCreated adds one" do
    ref = ingest.call(teams_install_activity)

    assert_instance_of TeamsConversation, ref
    assert_equal [ CHANNEL, SERVICE_URL, TENANT, TEAM, "McRitchie Studio", "installed", OWNER_AAD ],
                 [ ref.conversation_id, ref.service_url, ref.tenant_id, ref.team_id, ref.team_name, ref.status,
                   ref.installed_by_aad_object_id ]
    assert_equal 0, AgentMessage.where(channel: "teams").count

    created = teams_install_activity.except("membersAdded")
    created["channelData"] = created["channelData"].merge("eventType" => "channelCreated",
                                                          "channel" => { "id" => "19:new@thread.tacv2", "name" => "rolio" })
    assert_equal "rolio", ingest.call(created).name

    removed = teams_install_activity.except("membersAdded").merge("membersRemoved" => [ { "id" => "28:#{APP_ID}" } ])
    ingest.call(removed)
    assert_equal "removed", ref.reload.status

    member = teams_install_activity.merge("membersAdded" => [ { "id" => "29:a-person" } ])
    assert_nil ingest.call(member), "a person joining stores nothing"
  end
end
