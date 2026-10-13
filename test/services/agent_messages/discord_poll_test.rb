require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] + [integration] the inbound half: AgentMessages::DiscordIngest stores a
# message once and routes it; AgentMessages::DiscordPoll walks the allow-listed
# channels through a STUBBED Discord API and advances each cursor. No test here
# reaches Discord: the bot's transport is a lambda.
class AgentMessages::DiscordPollTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  # A fake Discord: { channel_id => [raw messages] }, answering the `after`
  # query the way the API does (newest first, only ids above `after`).
  class FakeDiscord
    attr_reader :calls

    def initialize(pages)
      @pages = pages
      @calls = []
    end

    def call(method, url, headers, _body)
      @calls << [ method, url, headers["Authorization"] ]
      channel = url[%r{/channels/(\d+)/messages}, 1]
      after = url[/after=(\d+)/, 1].to_i
      [ 200, JSON.generate(Array(@pages[channel]).select { |m| m["id"].to_i > after }.reverse) ]
    end
  end

  def bot(fake) = AgentMessages::DiscordBot.new(token: "test-token", transport: fake)

  def poll(fake, routes: agent_routes, now: Time.current)
    AgentMessages::DiscordPoll.new(routes: routes, bot: bot(fake), now: now).call
  end

  def ingest(raw, routes: agent_routes)
    AgentMessages::DiscordIngest.new(routes: routes).call(raw, guild_id: GUILD)
  end

  test "[unit] a routed message is stored once with its soul, mentions and timeline" do
    message = ingest(discord_raw(1001, content: "<@&#{AVI_ROLE}> is the release green?", roles: [ AVI_ROLE ]))

    assert_equal [ "avi", "role", "received" ], [ message.soul_slug, message.routed_by, message.status ]
    assert_equal({ "users" => [], "roles" => [ AVI_ROLE ] }, message.mentions)
    assert_equal "discord:#{DESK}:1001", message.thread_key
    assert_equal "Alex", message.author_name
    assert_equal %w[received routed], message.events.map(&:kind)
  end

  test "[unit] a message that addresses no soul is stored unrouted, never dropped" do
    message = ingest(discord_raw(1002, content: "just thinking out loud"))

    assert_equal "unrouted", message.status
    assert_nil message.soul_slug
    assert_equal %w[received unrouted], message.events.map(&:kind)
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
    assert_nil ingest(discord_raw(1004, content: "**Avi** · green", author: SHARED_BOT))
    assert_nil ingest(discord_raw(1005, content: "beep", bot: true))
    assert_equal 0, AgentMessage.where(external_id: %w[1004 1005]).count
  end

  test "[unit] a reply to an agent's answer continues that thread with that soul" do
    parent = ingest(discord_raw(1006, content: "<@&#{AVI_ROLE}> status?", roles: [ AVI_ROLE ]))
    parent.update!(reply_external_id: "1007")

    follow_up = ingest(discord_raw(1008, content: "and the one before?", reply_to: 1007))

    assert_equal [ "avi", "thread" ], [ follow_up.soul_slug, follow_up.routed_by ]
    assert_equal parent.thread_key, follow_up.thread_key
  end

  test "[unit] a reply that names another soul goes to that soul, in the same thread" do
    parent = ingest(discord_raw(1009, content: "<@&#{AVI_ROLE}> status?", roles: [ AVI_ROLE ]))
    follow_up = ingest(discord_raw(1010, content: "<@&#{XAN_ROLE}> your view?", roles: [ XAN_ROLE ], reply_to: 1009))

    assert_equal "xan", follow_up.soul_slug
    assert_equal parent.thread_key, follow_up.thread_key
  end

  test "[integration] a poll ingests and routes each allow-listed channel, then resumes from its cursor" do
    now = Time.current
    pages = {
      DESK => [ discord_raw(2001, content: "<@&#{AVI_ROLE}> release?", roles: [ AVI_ROLE ], at: now - 1.minute),
                discord_raw(2002, content: "<@&#{XAN_ROLE}> board?", roles: [ XAN_ROLE ], at: now - 30.seconds),
                discord_raw(2003, content: "no one in particular", at: now - 10.seconds) ],
      QUIET => []
    }
    fake = FakeDiscord.new(pages)

    summary = poll(fake, now: now)

    assert_equal 2, summary.channels
    assert_equal 3, summary.stored
    assert_equal({ "2001" => "avi", "2002" => "xan", "2003" => nil },
                 AgentMessage.where(external_id: %w[2001 2002 2003]).to_h { |m| [ m.external_id, m.soul_slug ] })
    assert_equal "2003", AgentMessageCursor.find_by(source_ref: DESK).cursor
    assert fake.calls.all? { |_, _, auth| auth == "Bot test-token" }

    pages[DESK] << discord_raw(2004, content: "<@&#{AVI_ROLE}> again", roles: [ AVI_ROLE ], at: now)
    second = poll(fake, now: now)

    assert_equal 1, second.stored
    assert_match(/after=2003/, fake.calls.select { |_, url, _| url.include?(DESK) }.last[1])
  end

  test "[integration] a duplicate poll page stores nothing new" do
    now = Time.current
    page = [ discord_raw(3001, content: "<@&#{AVI_ROLE}> hi", roles: [ AVI_ROLE ], at: now) ]
    poll(FakeDiscord.new(DESK => page), now: now)
    AgentMessageCursor.find_by(source_ref: DESK).update!(cursor: "3000") # the page is read again

    summary = poll(FakeDiscord.new(DESK => page), now: now)

    assert_equal 0, summary.stored
    assert_equal 1, AgentMessage.where(external_id: "3001").count
  end

  test "[integration] the first read of a channel skips history older than the bootstrap window" do
    now = Time.current
    page = [ discord_raw(4001, content: "<@&#{AVI_ROLE}> old", roles: [ AVI_ROLE ], at: now - 3.hours),
             discord_raw(4002, content: "<@&#{AVI_ROLE}> new", roles: [ AVI_ROLE ], at: now - 5.minutes) ]

    summary = poll(FakeDiscord.new(DESK => page), now: now)

    assert_equal 1, summary.stored
    assert_nil AgentMessage.find_by(external_id: "4001")
    assert_equal "4002", AgentMessageCursor.find_by(source_ref: DESK).cursor
  end

  test "[integration] a refused channel records its error and the pass moves on" do
    failing = ->(_m, url, _h, _b) { url.include?(DESK) ? [ 403, '{"message":"Missing Access"}' ] : [ 200, "[]" ] }

    summary = AgentMessages::DiscordPoll.new(routes: agent_routes, bot: bot(failing)).call

    assert_equal 2, summary.channels
    assert_match(/HTTP 403/, AgentMessageCursor.find_by(source_ref: DESK).last_error)
    refute_match(/test-token/, summary.errors.join)
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

  test "[unit] with a token but the shipped (empty) routes, the poll job reads nothing" do
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      AgentMessages::DiscordBot.stub(:new, ->(*) { flunk "no channel is configured, so no request is made" }) do
        assert_nil AgentMessageDiscordPollJob.perform_now
      end
    end
  ensure
    AgentMessageDiscordPollJob.announced_idle = false
  end
end
