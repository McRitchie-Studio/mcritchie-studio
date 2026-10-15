require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] + [integration] the inbound half: AgentMessages::DiscordIngest stores an
# ADDRESSED message once and routes it, and drops the rest unstored;
# AgentMessages::DiscordPoll, the backstop, enumerates each listed guild's text
# channels and active threads through a STUBBED Discord API and advances each
# cursor. No test here reaches Discord: the bot's transport is a lambda.
class AgentMessages::DiscordPollTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  # A fake Discord. `pages` is { channel_id => [raw messages] }, answered the way
  # the API does (newest first, only ids above `after`). The guild's channel
  # list is every key of `pages` as a text channel unless `channels` is given;
  # `threads` is the active-thread list.
  class FakeDiscord
    attr_reader :calls

    def initialize(pages, channels: nil, threads: [])
      @pages = pages
      @channels = channels || pages.keys.map { |id| { "id" => id, "type" => 0 } }
      @threads = threads
      @calls = []
    end

    def call(method, url, headers, _body)
      @calls << [ method, url, headers["Authorization"] ]
      return [ 200, JSON.generate(@channels) ] if url.end_with?("/channels") && url.include?("/guilds/")
      return [ 200, JSON.generate("threads" => @threads, "members" => []) ] if url.end_with?("/threads/active")

      channel = url[%r{/channels/(\d+)/messages}, 1]
      after = url[/after=(\d+)/, 1].to_i
      [ 200, JSON.generate(Array(@pages[channel]).select { |m| m["id"].to_i > after }.reverse) ]
    end

    def message_reads = @calls.filter_map { |_, url, _| url[%r{/channels/(\d+)/messages}, 1] }
  end

  def bot(fake) = AgentMessages::DiscordBot.new(token: "test-token", transport: fake)

  def poll(fake, routes: agent_routes, now: Time.current)
    AgentMessages::DiscordPoll.new(routes: routes, bot: bot(fake), now: now).call
  end

  def ingest(raw, routes: agent_routes, guild: GUILD, parent_id: nil)
    AgentMessages::DiscordIngest.new(routes: routes).call(raw, guild_id: guild, parent_id: parent_id)
  end

  setup { AgentMessages::DiscordIngest.reset_unlisted_guilds! }

  # --- the addressed-only filter ---------------------------------------------

  test "[unit] a routed message is stored once with its soul, mentions and timeline" do
    message = ingest(discord_raw(1001, content: "<@&#{AVI_ROLE}> is the release green?", roles: [ AVI_ROLE ]))

    assert_equal [ "avi", "role", "received" ], [ message.soul_slug, message.routed_by, message.status ]
    assert_equal({ "users" => [], "roles" => [ AVI_ROLE ] }, message.mentions)
    assert_equal "discord:#{DESK}:1001", message.thread_key
    assert_equal "Alex", message.author_name
    assert_equal %w[received routed], message.events.map(&:kind)
    assert_equal "discord-poll", message.events.first.actor
  end

  test "[unit] a message that addresses no soul is dropped, not stored" do
    assert_nil ingest(discord_raw(1002, content: "just thinking out loud"))
    assert_nil ingest(discord_raw(1012, content: "lunch?", channel: LOUNGE))
    assert_nil ingest(discord_raw(1013, content: "<@#{SHARED_BOT}> not a soul", users: [ SHARED_BOT ]))
    assert_equal 0, AgentMessage.where(external_id: %w[1002 1012 1013]).count
  end

  test "[unit] a channel with no entry is in scope: a mention there is stored and routed" do
    message = ingest(discord_raw(1014, content: "<@&#{XAN_ROLE}> board?", channel: LOUNGE, roles: [ XAN_ROLE ]))

    assert_equal [ "xan", "role", LOUNGE ], [ message.soul_slug, message.routed_by, message.channel_ref ]
  end

  test "[unit] ingesting the same message twice stores one row" do
    raw = discord_raw(1003, content: "<@&#{XAN_ROLE}> board?", roles: [ XAN_ROLE ])
    first = ingest(raw)
    again = ingest(raw)

    assert_equal first.id, again.id
    assert_equal 1, AgentMessage.where(external_id: "1003").count
    assert_equal 2, first.events.count, "a repeat writes no second timeline"
  end

  test "[unit] a bot's message (our own replies included) is not inbound" do
    assert_nil ingest(discord_raw(1004, content: "<@&#{AVI_ROLE}> green", roles: [ AVI_ROLE ], author: SHARED_BOT))
    assert_nil ingest(discord_raw(1005, content: "<@&#{AVI_ROLE}> beep", roles: [ AVI_ROLE ], bot: true))
    assert_equal 0, AgentMessage.where(external_id: %w[1004 1005]).count
  end

  test "[unit] a reply to an agent's answer continues that thread with that soul, unmentioned" do
    parent = ingest(discord_raw(1006, content: "<@&#{AVI_ROLE}> status?", roles: [ AVI_ROLE ]))
    parent.update!(reply_external_id: "1007")

    follow_up = ingest(discord_raw(1008, content: "and the one before?", reply_to: 1007))

    assert_equal [ "avi", "thread" ], [ follow_up.soul_slug, follow_up.routed_by ]
    assert_equal parent.thread_key, follow_up.thread_key
  end

  test "[unit] a reply to a message the mailbox does not hold is chatter, and dropped" do
    assert_nil ingest(discord_raw(1011, content: "agreed", reply_to: 424_242))
  end

  test "[unit] a reply that names another soul goes to that soul, in the same thread" do
    parent = ingest(discord_raw(1009, content: "<@&#{AVI_ROLE}> status?", roles: [ AVI_ROLE ]))
    follow_up = ingest(discord_raw(1010, content: "<@&#{XAN_ROLE}> your view?", roles: [ XAN_ROLE ], reply_to: 1009))

    assert_equal "xan", follow_up.soul_slug
    assert_equal parent.thread_key, follow_up.thread_key
  end

  # A Discord FORWARD is a type-0 message whose message_reference (type 1) points
  # at a message in another channel. It is not a reply: it must never join the
  # referenced row's thread or inherit its soul.
  def forward(id, of:, from_channel:, into:, from_guild: GUILD, **opts)
    discord_raw(id, channel: into, **opts).merge(
      "message_reference" => { "type" => 1, "message_id" => of.to_s, "channel_id" => from_channel, "guild_id" => from_guild }
    )
  end

  test "[unit] forwarding a held message from another channel does not join its thread or inherit its soul" do
    held = ingest(discord_raw(1020, content: "<@&#{AVI_ROLE}> status?", roles: [ AVI_ROLE ], channel: LOUNGE))
    held.update!(reply_external_id: "1021")

    assert_nil ingest(forward(1022, of: 1020, from_channel: LOUNGE, into: DESK, content: "")),
               "an unaddressed forward is chatter, dropped"
    assert_nil ingest(forward(1023, of: 1021, from_channel: LOUNGE, into: DESK, content: "")),
               "a forward of the agent's answer is chatter too"

    addressed = ingest(forward(1024, of: 1020, from_channel: LOUNGE, into: DESK, content: "<@&#{XAN_ROLE}> see this",
                               roles: [ XAN_ROLE ]))
    assert_equal [ "xan", "role", "discord:#{DESK}:1024" ],
                 [ addressed.soul_slug, addressed.routed_by, addressed.thread_key ],
                 "an addressed forward starts its own thread"
    refute_equal held.thread_key, addressed.thread_key
  end

  test "[unit] a reference into another channel or guild is refused even without the forward type" do
    held = ingest(discord_raw(1030, content: "<@&#{AVI_ROLE}> status?", roles: [ AVI_ROLE ], channel: LOUNGE))

    # Claims this channel, but the held row lives in LOUNGE: no cross-channel join.
    assert_nil ingest(discord_raw(1031, content: "and?", reply_to: 1030, channel: DESK))
    other_guild = discord_raw(1032, content: "and?", reply_to: 1030, channel: LOUNGE)
    other_guild["message_reference"].merge!("channel_id" => LOUNGE, "guild_id" => OTHER_GUILD)
    assert_nil ingest(other_guild), "a reference naming another guild is refused"

    same = ingest(discord_raw(1033, content: "and?", reply_to: 1030, channel: LOUNGE))
    assert_equal [ "avi", "thread", held.thread_key ], [ same.soul_slug, same.routed_by, same.thread_key ],
                 "a reply in the same channel still joins"
  end

  # --- overrides, ignore, and the guild boundary ------------------------------

  test "[unit] a default_soul override stores its channel's unaddressed messages, and its threads'" do
    routes = agent_routes(default_soul: "avi")

    in_channel = ingest(discord_raw(1020, content: "anyone?"), routes: routes)
    in_thread = ingest(discord_raw(1021, content: "anyone?", channel: DESK_THREAD), routes: routes, parent_id: DESK)

    assert_equal [ "avi", "default" ], [ in_channel.soul_slug, in_channel.routed_by ]
    assert_equal [ "avi", "default" ], [ in_thread.soul_slug, in_thread.routed_by ]
    assert_nil ingest(discord_raw(1022, content: "anyone?", channel: LOUNGE), routes: routes),
               "the override is the channel's, not the guild's"
  end

  test "[unit] an ignored channel stores nothing, mentions included, and neither do its threads" do
    assert_nil ingest(discord_raw(1030, content: "<@&#{AVI_ROLE}> hi", channel: MUTED, roles: [ AVI_ROLE ]))
    assert_nil ingest(discord_raw(1031, content: "<@&#{AVI_ROLE}> hi", channel: "900000000000000050",
                                  roles: [ AVI_ROLE ]), parent_id: MUTED)
    assert_equal 0, AgentMessage.where(external_id: %w[1030 1031]).count
  end

  test "[unit] a guild that is not listed is ignored, and the log names it once" do
    log = StringIO.new
    Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
      2.times do |i|
        raw = discord_raw(1040 + i, content: "<@&#{AVI_ROLE}> hi", roles: [ AVI_ROLE ], channel: "1")
        assert_nil ingest(raw, guild: OTHER_GUILD)
      end
    end

    assert_equal 1, log.string.scan(/ignoring Discord guild #{OTHER_GUILD}: not listed/).size
    assert_equal 0, AgentMessage.where(external_id: %w[1040 1041]).count
  end

  # --- the backstop poll -----------------------------------------------------

  test "[integration] the backstop reads every text channel and active thread of the guild, storing only addressed messages" do
    now = Time.current
    pages = {
      DESK => [ discord_raw(2001, content: "<@&#{AVI_ROLE}> release?", roles: [ AVI_ROLE ], at: now - 1.minute),
                discord_raw(2002, content: "no one in particular", at: now - 30.seconds) ],
      LOUNGE => [ discord_raw(2003, content: "<@&#{XAN_ROLE}> board?", channel: LOUNGE, roles: [ XAN_ROLE ],
                              at: now - 20.seconds) ],
      MUTED => [ discord_raw(2004, content: "<@&#{XAN_ROLE}> hi", channel: MUTED, roles: [ XAN_ROLE ], at: now) ],
      DESK_THREAD => [ discord_raw(2005, content: "<@&#{AVI_ROLE}> in the thread", channel: DESK_THREAD,
                                   roles: [ AVI_ROLE ], at: now - 10.seconds) ]
    }
    channels = [ { "id" => DESK, "type" => 0 }, { "id" => LOUNGE, "type" => 5 }, { "id" => MUTED, "type" => 0 },
                 { "id" => "900000000000000060", "type" => 2 },  # voice
                 { "id" => "900000000000000061", "type" => 4 },  # category
                 { "id" => "900000000000000062", "type" => 15 } ] # forum: its posts come as threads
    fake = FakeDiscord.new(pages, channels: channels, threads: [ { "id" => DESK_THREAD, "parent_id" => DESK, "type" => 11 } ])

    summary = poll(fake, now: now)

    assert_equal [ DESK, LOUNGE, DESK_THREAD ], fake.message_reads.uniq, "text, announcement and thread; never muted, voice, category or forum"
    assert_equal 3, summary.channels
    assert_equal 3, summary.stored
    assert_equal({ "2001" => "avi", "2003" => "xan", "2005" => "avi" },
                 AgentMessage.where(external_id: %w[2001 2002 2003 2004 2005]).to_h { |m| [ m.external_id, m.soul_slug ] })
    assert_equal "2002", AgentMessageCursor.find_by(source_ref: DESK).cursor, "the cursor passes dropped chatter too"
    assert fake.calls.all? { |_, _, auth| auth == "Bot test-token" }

    pages[DESK] << discord_raw(2006, content: "<@&#{AVI_ROLE}> again", roles: [ AVI_ROLE ], at: now)
    second = poll(fake, now: now)

    assert_equal 1, second.stored
    assert_match(/after=2002/, fake.calls.select { |_, url, _| url.include?("/channels/#{DESK}/messages") }.last[1])
  end

  test "[integration] a duplicate poll page stores nothing new" do
    now = Time.current
    page = [ discord_raw(3001, content: "<@&#{AVI_ROLE}> hi", roles: [ AVI_ROLE ], at: now) ]
    poll(FakeDiscord.new({ DESK => page }), now: now)
    AgentMessageCursor.find_by(source_ref: DESK).update!(cursor: "3000") # the page is read again

    summary = poll(FakeDiscord.new({ DESK => page }), now: now)

    assert_equal 0, summary.stored
    assert_equal 1, AgentMessage.where(external_id: "3001").count
  end

  test "[integration] the first read of a channel skips history older than the bootstrap window" do
    now = Time.current
    page = [ discord_raw(4001, content: "<@&#{AVI_ROLE}> old", roles: [ AVI_ROLE ], at: now - 3.hours),
             discord_raw(4002, content: "<@&#{AVI_ROLE}> new", roles: [ AVI_ROLE ], at: now - 5.minutes) ]

    summary = poll(FakeDiscord.new({ DESK => page }), now: now)

    assert_equal 1, summary.stored
    assert_nil AgentMessage.find_by(external_id: "4001")
    assert_equal "4002", AgentMessageCursor.find_by(source_ref: DESK).cursor
  end

  test "[integration] a refused channel records its error and the pass moves on" do
    fake = FakeDiscord.new({ DESK => [], QUIET => [] })
    failing = lambda do |m, url, h, b|
      url.include?("/channels/#{DESK}/messages") ? [ 403, '{"message":"Missing Access"}' ] : fake.call(m, url, h, b)
    end

    summary = AgentMessages::DiscordPoll.new(routes: agent_routes, bot: bot(failing)).call

    assert_equal 2, summary.channels
    assert_match(/HTTP 403/, AgentMessageCursor.find_by(source_ref: DESK).last_error)
    assert_includes fake.message_reads, QUIET
    refute_match(/test-token/, summary.errors.join)
  end

  test "[integration] a rate limit stops the pass, on a channel read or on the guild listing" do
    fake = FakeDiscord.new({ DESK => [], QUIET => [] })
    limited_read = lambda do |m, url, h, b|
      url.include?("/messages") ? [ 429, '{"retry_after": 2.5}' ] : fake.call(m, url, h, b)
    end
    summary = AgentMessages::DiscordPoll.new(routes: agent_routes, bot: bot(limited_read)).call
    assert_equal 1, summary.channels, "the pass stops at the first rate-limited channel"
    assert_match(/retry after 2.5/, summary.errors.join)

    limited_list = ->(*) { [ 429, '{"retry_after": 1}' ] }
    summary = AgentMessages::DiscordPoll.new(routes: agent_routes, bot: bot(limited_list)).call
    assert_equal 0, summary.channels
    assert_match(/retry after 1/, summary.errors.join)
  end

  # The gateway and the poll racing on one message: the poll's find_by misses,
  # then the gateway's insert COMMITS from another backend. It lands either
  # before the poll's uniqueness validation (RecordInvalid) or between that
  # validation and the INSERT (the unique index: RecordNotUnique, inside the
  # poll's cursor transaction, where only a savepoint keeps the transaction
  # usable for the rescue's re-read and the cursor advance).
  def race_gateway_insert(external_id, &poll)
    config = ActiveRecord::Base.connection_pool.db_config
    @gateway_db = config.adapter_class.new(config.configuration_hash)
    @raced = false
    race = lambda do
      next if @raced

      @raced = true
      # The gateway's row, committed on its own connection (autocommit).
      @gateway_db.exec_insert(<<~SQL.squish, "gateway insert", [ external_id, GUILD, DESK, "discord:gateway:#{external_id}" ])
        INSERT INTO agent_messages (channel, external_id, guild_id, channel_ref, thread_key, soul_slug, routed_by,
                                    status, created_at, updated_at)
        VALUES ('discord', $1, $2, $3, $4, 'avi', 'role', 'received', now(), now())
      SQL
    end
    poll.call(race) # the block asserts, before the cleanup below
  ensure
    @gateway_db&.exec_delete("DELETE FROM agent_messages WHERE channel = 'discord' AND external_id = '#{external_id}'")
    @gateway_db&.disconnect!
  end

  def assert_race_survived(summary, external_id)
    assert @raced, "the race hook ran"
    assert_empty summary.errors, "the pass reports success"
    assert_equal [ 0, 1 ], [ summary.stored, summary.skipped ], "the gateway's row is the one kept"
    assert_equal 1, AgentMessage.where(channel: "discord", external_id: external_id).count
    assert_equal external_id, AgentMessageCursor.find_by!(channel: "discord", source_ref: DESK).cursor,
                 "the cursor advanced past the raced message in the same transaction"
  end

  test "[integration] a gateway insert that lands past the poll's validation leaves one row, and the poll pass succeeds" do
    raw = discord_raw(4242, content: "<@&#{AVI_ROLE}> raced", roles: [ AVI_ROLE ])
    race_gateway_insert("4242") do |race|
      hook = ->(_record) { race.call }
      AgentMessage.set_callback(:create, :before, hook)
      begin
        assert_race_survived(poll(FakeDiscord.new({ DESK => [ raw ] })), "4242")
      ensure
        AgentMessage.skip_callback(:create, :before, hook)
      end
    end
  end

  test "[integration] a gateway insert that lands before the poll's validation leaves one row, and the poll pass succeeds" do
    raw = discord_raw(4243, content: "<@&#{AVI_ROLE}> raced", roles: [ AVI_ROLE ])
    original = AgentMessage.method(:create!)
    race_gateway_insert("4243") do |race|
      racing_create = lambda do |*args, **kwargs, &block|
        race.call
        original.call(*args, **kwargs, &block)
      end
      summary = AgentMessage.stub(:create!, racing_create) { poll(FakeDiscord.new({ DESK => [ raw ] })) }
      assert_race_survived(summary, "4243")
    end
  end

  test "[unit] the poll job is inert without a token, and says so once" do
    with_env("DISCORD_AGENT_BOT_TOKEN", nil) do
      AgentMessageDiscordPollJob.announced_idle = false
      logged = []
      Rails.logger.stub(:info, ->(line) { logged << line }) do
        assert_nil AgentMessageDiscordPollJob.perform_now
        assert_nil AgentMessageDiscordPollJob.perform_now
      end
      assert_equal 1, logged.grep(/discord poll idle: DISCORD_AGENT_BOT_TOKEN is unset/).size
    end
  ensure
    AgentMessageDiscordPollJob.announced_idle = false
  end

  test "[unit] with a token but no guild listed, the poll job reads nothing" do
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      AgentMessages::Routes.stub(:load, AgentMessages::Routes.new({})) do
        AgentMessages::DiscordBot.stub(:new, ->(*) { flunk "no guild is configured, so no request is made" }) do
          assert_nil AgentMessageDiscordPollJob.perform_now
        end
      end
    end
  ensure
    AgentMessageDiscordPollJob.announced_idle = false
  end
end
