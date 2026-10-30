require "test_helper"
require_relative "../../support/agent_message_fixtures"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [unit] AgentMessages::SlackIngest and SlackRoutes: an Events API message
# normalized into an agent_messages row; bots, edits and other workspaces
# filtered; a repeat delivery deduped on (channel, external_id); routing by
# name, thread, app mention / DM and channel default; the owner-only guard.
class AgentMessages::SlackIngestTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  TEAM = "T0TEST0001".freeze
  CHAN = "C0AGENTS01".freeze
  DESK = "C0DESK0001".freeze
  MUTE = "C0MUTE0001".freeze
  BOT = "U0APPBOT01".freeze
  ALEX = "U0OWNER001".freeze
  STRANGER = "U0OTHER001".freeze

  def routes(**extra)
    AgentMessages::SlackRoutes.new({
      "team_id" => TEAM, "bot_user_id" => BOT, "owner_user_id" => ALEX, "mention_soul" => "alex",
      "souls" => { "avi" => { "names" => [ "Avi" ] }, "alex" => { "names" => [ "Alex" ] },
                   "turf_monster" => { "names" => [ "Turf" ] } },
      "channels" => { DESK => { "name" => "desk", "default_soul" => "avi" }, MUTE => { "ignore" => true } }
    }.merge(extra.deep_stringify_keys))
  end

  def ingest(r = routes, answerers: AgentMessages::Answerers.current) = AgentMessages::SlackIngest.new(routes: r, answerers: answerers)

  def event(text, **attrs)
    { "type" => "message", "channel" => CHAN, "channel_type" => "channel", "user" => ALEX, "text" => text,
      "ts" => "1761800000.#{format('%06d', rand(1_000_000))}" }.merge(attrs.deep_stringify_keys)
  end

  test "[unit] normalize: a named message becomes a slack row keyed C…:ts, threaded on its own ts, team as guild" do
    e = event("Avi, what shipped today?")
    row = ingest.call(e, team_id: TEAM, event_id: "Ev1")

    assert_equal "slack", row.channel
    assert_equal "#{CHAN}:#{e['ts']}", row.external_id
    assert_equal [ TEAM, CHAN, "slack:#{CHAN}:#{e['ts']}" ], [ row.guild_id, row.channel_ref, row.thread_key ]
    assert_equal [ "avi", "name", "received" ], [ row.soul_slug, row.routed_by, row.status ]
    assert_equal ALEX, row.author_ref
    assert_equal "slack", row.person.identities.first.platform
    assert_equal({ "channel_type" => "channel", "event_id" => "Ev1" }, row.envelope)
    assert_equal Time.zone.at(e["ts"].to_f).to_i, row.sent_at.to_i
    assert_equal %w[received routed], row.events.map(&:kind)
  end

  test "[unit] a leading @-mention of the app is read past, so '@McRitchie Agents Turf, …' is for Turf" do
    row = ingest.call(event("<@#{BOT}> Turf, any scores?"), team_id: TEAM)
    assert_equal [ "turf_monster", "name" ], [ row.soul_slug, row.routed_by ]
    assert_equal [ BOT ], row.mentions["users"]
  end

  test "[unit] a bare app mention or app_mention event, and a DM, go to the mention soul" do
    row = ingest.call(event("<@#{BOT}> hello there"), team_id: TEAM)
    assert_equal [ "alex", "mention" ], [ row.soul_slug, row.routed_by ]

    row = ingest.call(event("hi", "type" => "app_mention", "channel_type" => nil), team_id: TEAM)
    assert_equal [ "alex", "mention" ], [ row.soul_slug, row.routed_by ]

    dm = ingest.call(event("what's on today?", "channel" => "D0DIRECT01", "channel_type" => "im"), team_id: TEAM)
    assert_equal [ "alex", "mention", "im" ], [ dm.soul_slug, dm.routed_by, dm.envelope["channel_type"] ]
  end

  test "[unit] a name in the middle of a sentence is not an address; an unaddressed message is dropped unstored" do
    assert_no_difference -> { AgentMessage.count } do
      assert_nil ingest.call(event("I told Avi, then left"), team_id: TEAM)
      assert_nil ingest.call(event("lunch?"), team_id: TEAM)
    end
  end

  test "[unit] a channel default routes its unaddressed messages; a name still wins there" do
    assert_equal [ "avi", "default" ], ingest.call(event("deploy is red", "channel" => DESK), team_id: TEAM).then { [ _1.soul_slug, _1.routed_by ] }
    assert_equal "turf_monster", ingest.call(event("Turf: odds?", "channel" => DESK), team_id: TEAM).soul_slug
  end

  test "[unit] thread inheritance: a reply in a held thread keeps the thread's soul and key; a name in it re-routes" do
    root = ingest.call(event("Avi, look at the release"), team_id: TEAM)
    root_ts = root.external_id.split(":").last

    reply = ingest.call(event("and the QA one too", "thread_ts" => root_ts), team_id: TEAM)
    assert_equal [ "avi", "thread", root.thread_key ], [ reply.soul_slug, reply.routed_by, reply.thread_key ]
    assert_equal root_ts, reply.envelope["thread_ts"]

    named = ingest.call(event("Turf, you too", "thread_ts" => root_ts), team_id: TEAM)
    assert_equal [ "turf_monster", "name", root.thread_key ], [ named.soul_slug, named.routed_by, named.thread_key ]

    mention = ingest.call(event("<@#{BOT}> still there?", "thread_ts" => root_ts), team_id: TEAM)
    assert_equal [ "avi", "thread" ], [ mention.soul_slug, mention.routed_by ], "an app mention names the app, not a soul: the thread wins"
  end

  test "[unit] a reply in a thread the mailbox does not hold is unaddressed" do
    assert_nil ingest.call(event("sure", "thread_ts" => "1761700000.000100"), team_id: TEAM)
  end

  test "[unit] bot filter: bot_id, bot_profile, subtype bot_message and the app's own user are never ingested" do
    assert_no_difference -> { AgentMessage.count } do
      assert_nil ingest.call(event("Avi, hi", "bot_id" => "B0STEFFON1", "user" => "U0CDGFHDL7K"), team_id: TEAM)
      assert_nil ingest.call(event("Avi, hi", "bot_profile" => { "name" => "x" }), team_id: TEAM)
      assert_nil ingest.call(event("Avi, hi", "subtype" => "bot_message", "user" => nil), team_id: TEAM)
      assert_nil ingest.call(event("Avi, hi", "user" => BOT), team_id: TEAM)
    end
  end

  test "[unit] edits, deletes, joins, other event types, a muted channel and another workspace are ignored" do
    assert_no_difference -> { AgentMessage.count } do
      %w[message_changed message_deleted channel_join].each do |subtype|
        assert_nil ingest.call(event("Avi, hi", "subtype" => subtype), team_id: TEAM)
      end
      assert_nil ingest.call(event("Avi, hi", "type" => "reaction_added"), team_id: TEAM)
      assert_nil ingest.call(event("Avi, hi", "channel" => MUTE), team_id: TEAM)
      assert_nil ingest.call(event("Avi, hi"), team_id: "T0SOMEONE9")
    end
    assert_nil AgentMessages::SlackIngest.new(routes: routes("team_id" => nil)).call(event("Avi, hi"), team_id: TEAM),
               "no team configured: nothing is read"
  end

  test "[unit] dedupe: a repeat delivery (Slack's retry, or message + app_mention for one ts) returns the first row" do
    e = event("<@#{BOT}> Avi, status?")
    first = ingest.call(e, team_id: TEAM)
    assert_no_difference -> { AgentMessage.count } do
      assert_equal first, ingest.call(e, team_id: TEAM)
      assert_equal first, ingest.call(e.merge("type" => "app_mention"), team_id: TEAM)
    end
  end

  test "[unit] dedupe under a race: the unique index's loser gets the winner's row" do
    e = event("Avi, race")
    winner = ingest.call(e, team_id: TEAM)
    racer = ingest
    # The pre-check misses (as for two deliveries racing); the insert collides.
    calls = 0
    finder = lambda do |**kw|
      calls += 1
      calls == 1 ? nil : AgentMessage.where(kw).first
    end
    AgentMessage.stub(:find_by, finder) do
      assert_equal winner, racer.call(e, team_id: TEAM)
    end
  end

  test "[unit] the owner-only guard: a stranger's routed message is held; the owner's linked Slack user is answered" do
    AgentMessages::Answerers.reset!
    with_routes(routes) do
      owner = AgentPerson.seed_owner!
      assert owner.identities.exists?(platform: "slack", external_id: ALEX), "seed_owner! links slack.owner_user_id"

      mine = ingest(answerers: AgentMessages::Answerers.current).call(event("Avi, hi"), team_id: TEAM)
      assert_equal [ "received", owner.id ], [ mine.status, mine.person_id ]

      theirs = ingest(answerers: AgentMessages::Answerers.current).call(event("Avi, hi", "user" => STRANGER), team_id: TEAM)
      assert_equal "held", theirs.status
      assert theirs.events.exists?(kind: "held")
    end
  end

  test "[unit] SlackRoutes: the shipped block names the workspace, the app bot, the owner and every routed soul" do
    shipped = AgentMessages::SlackRoutes.load
    assert_equal [ "T0CC9DQ9NAK", "U0CE93ACBA4", "U0CCSMUMQJV" ], [ shipped.team_id, shipped.bot_user_id, shipped.owner_user_id ]
    assert_nil shipped.default_soul("C0CD8ETBZBM"), "#agents is name- or mention-routed"
    refute shipped.ignored?("C0CD8ETBZBM")
    assert_includes AgentMessages::Routes.load.souls, shipped.mention_soul
    shipped.routed_souls.each { |soul| assert_includes AgentMailbox.routed_souls, soul, "bin/dispatcher serves #{soul}" }
  end

  # --- CLEARANCE (slack-agent-channel-guardrails) ---------------------------

  GENERAL = "C0GENERAL1".freeze
  TURFCH = "C0TURFAPP1".freeze
  BARE = "C0BAREAPP1".freeze

  def guarded_routes
    routes(
      "souls" => { "avi" => { "names" => [ "Avi" ] }, "alex" => { "names" => [ "Alex" ] },
                   "turf_monster" => { "names" => [ "Turf" ] }, "mason" => { "names" => [ "Mason" ] },
                   "steffon" => { "names" => [ "Steffon" ] }, "mack" => { "names" => [ "Mack" ] },
                   "tywin" => { "names" => [ "Tywin" ] } },
      "core_souls" => %w[alex steffon mason mack avi],
      "channels" => { GENERAL => { "name" => "agents-general", "open" => true },
                      TURFCH => { "name" => "turf-monster", "souls" => [ "turf_monster" ], "default_soul" => "turf_monster" },
                      BARE => { "name" => "rolio", "souls" => [] },
                      DESK => { "name" => "desk", "default_soul" => "avi" } }
    )
  end

  test "[unit] SlackRoutes clearance: open admits all, souls: admits core plus its own, no config admits all" do
    r = guarded_routes
    %w[tywin turf_monster tyrion mason].each { |soul| assert r.cleared?(GENERAL, soul), "#agents-general is open to #{soul}" }

    %w[turf_monster alex steffon mason mack avi].each { |soul| assert r.cleared?(TURFCH, soul), "#{soul} is cleared in #turf-monster" }
    %w[tywin tyrion hank].each { |soul| refute r.cleared?(TURFCH, soul), "#{soul} is not cleared in #turf-monster" }
    assert_equal %w[alex steffon mason mack avi turf_monster], r.cleared_souls(TURFCH)

    assert_equal %w[alex steffon mason mack avi], r.cleared_souls(BARE), "souls: [] is the core five only"
    refute r.cleared?(BARE, "turf_monster")

    [ DESK, CHAN, "D0DIRECT01" ].each do |ch|
      assert r.cleared?(ch, "tywin"), "#{ch}: no clearance config keeps today's behaviour"
      assert_nil r.cleared_souls(ch)
    end
    assert_match(/soul not cleared for this channel: tywin may not answer in #turf-monster/, r.clearance_reason(TURFCH, "tywin"))
  end

  test "[unit] name routing: Mason, Steffon, Mack and Tywin are addressable by name" do
    r = guarded_routes
    { "Mason, hello" => "mason", "Steffon: rotate the key" => "steffon", "Hi Mack, the books?" => "mack",
      "@Tywin status" => "tywin", "<@#{BOT}> Mason, you there?" => "mason" }.each do |text, soul|
      assert_equal soul, r.named(text), text
    end
    assert_nil r.named("Mackenzie, hi"), "a longer word is not the name"

    row = ingest(r).call(event("Mason, hello", "channel" => GENERAL), team_id: TEAM)
    assert_equal [ "mason", "name", "received" ], [ row.soul_slug, row.routed_by, row.status ]
  end

  test "[unit] held for clearance: a soul named in a channel it is not cleared for is stored held with the reason" do
    owner = AgentPerson.seed_owner!
    with_routes(guarded_routes) do
      row = ingest(guarded_routes).call(event("Tywin, how are the players?", "channel" => TURFCH), team_id: TEAM)
      assert_equal [ "tywin", "name", "held", owner.id ], [ row.soul_slug, row.routed_by, row.status, row.person_id ]
      hold = row.events.find_by!(kind: "held")
      assert_equal "slack-clearance", hold.actor
      assert_match(/soul not cleared for this channel/, hold.detail["reason"])
      refute_match(/sender's role/, hold.detail["reason"], "the owner is answered: clearance is the only cause")
      assert_equal %w[alex steffon mason mack avi turf_monster], hold.detail["cleared"]
      assert_equal %w[received routed held], row.events.order(:id).map(&:kind)
      assert_nil AgentMessage.claim!(soul: %w[tywin], worker: "w1").message, "a clearance hold is never claimed"

      cleared = ingest(guarded_routes).call(event("Mason, hello", "channel" => TURFCH), team_id: TEAM)
      assert_equal [ "mason", "received" ], [ cleared.soul_slug, cleared.status ]
      default = ingest(guarded_routes).call(event("odds are stale", "channel" => TURFCH), team_id: TEAM)
      assert_equal [ "turf_monster", "default", "received" ], [ default.soul_slug, default.routed_by, default.status ]
    end
  end

  test "[unit] held for clearance by thread: a reply that inherits an uncleared soul is held too" do
    AgentPerson.seed_owner!
    with_routes(guarded_routes) do
      root = ingest(guarded_routes).call(event("Tywin, hi", "channel" => TURFCH), team_id: TEAM)
      reply = ingest(guarded_routes).call(event("still there?", "channel" => TURFCH, "thread_ts" => root.external_id.split(":").last),
                                          team_id: TEAM)
      assert_equal [ "tywin", "thread", "held" ], [ reply.soul_slug, reply.routed_by, reply.status ]
    end
  end

  test "[unit] a stranger naming an uncleared soul: one held event names both causes" do
    AgentMessages::Answerers.reset!
    with_routes(guarded_routes) do
      row = ingest(guarded_routes, answerers: AgentMessages::Answerers.current)
            .call(event("Tywin, hi", "channel" => TURFCH, "user" => STRANGER), team_id: TEAM)
      assert_equal "held", row.status
      hold = row.events.where(kind: "held").sole
      assert_match(/soul not cleared.*; sender's role \(public\) is not answered/, hold.detail["reason"])
    end
  end

  test "[unit] the shipped clearance: agents-general open, app channels guarded, ops and releases unguarded, Tyrion nowhere" do
    shipped = AgentMessages::SlackRoutes.load
    assert_equal %w[alex steffon mason mack avi], shipped.core_souls
    assert shipped.override("C0CD8ETBZBM").open?, "#agents-general is open"
    assert_equal "agents-general", shipped.channel_name("C0CD8ETBZBM")
    %w[C0CDEG43ECS C0CDJCN4L92].each { |id| assert_nil shipped.cleared_souls(id), "#{shipped.channel_name(id)} keeps today's behaviour" }

    by_name = %w[turf-monster cyvasse commercial-welding alex-build rolio].to_h do |name|
      id = shipped.instance_variable_get(:@overrides).values.find { _1.name == name }&.channel_id
      assert id, "##{name} is configured"
      [ name, id ]
    end
    assert_includes shipped.cleared_souls(by_name["turf-monster"]), "turf_monster"
    assert_equal "turf_monster", shipped.default_soul(by_name["turf-monster"])
    assert_includes shipped.cleared_souls(by_name["cyvasse"]), "tywin"
    assert_equal "tywin", shipped.default_soul(by_name["cyvasse"])
    assert_includes shipped.cleared_souls(by_name["commercial-welding"]), "hank"
    assert_equal shipped.core_souls, shipped.cleared_souls(by_name["rolio"])
    refute shipped.cleared?(by_name["cyvasse"], "turf_monster")

    shipped.instance_variable_get(:@overrides).each_value do |entry|
      refute_includes Array(entry.souls), "tyrion", "Tyrion is client-facing: never cleared in ##{entry.name}"
      next unless entry.default_soul

      assert shipped.cleared?(entry.channel_id, entry.default_soul), "##{entry.name}'s default soul is cleared there"
    end
  end

  test "[unit] the dispatcher can run every Slack soul: each is served and has a role doc for its owner persona" do
    shipped = AgentMessages::SlackRoutes.load
    %w[mason steffon mack tywin].each { |soul| assert_includes shipped.souls.keys, soul }
    owner = AgentMailbox::Audience.new(role: "owner")
    shipped.souls.each_key do |soul|
      assert_includes AgentMailbox.routed_souls, soul, "bin/dispatcher serves #{soul}"
      assert Rails.root.join("docs/agents/agents/#{soul}/role.md").file?, "#{soul} has the role doc the respond path reads"
      layer = AgentMailbox::ContextBuilder.new(soul: soul, message: { "id" => 1, "channel" => "slack", "content" => "hi" },
                                               context: {}, repo_root: Rails.root.to_s, audience: owner).general_layer
      refute_includes layer, "no role doc found", soul
    end
  end

  private

  def with_routes(r)
    original = AgentMessages::SlackRoutes.instance_variable_get(:@current)
    AgentMessages::SlackRoutes.current = r
    yield
  ensure
    AgentMessages::SlackRoutes.current = original
  end
end
