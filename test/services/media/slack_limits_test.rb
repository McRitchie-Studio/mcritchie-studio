require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] The Slack noise caps at the outbound seam (Media::Slack::Limits, read
# by Media::Slack#post and #deliver_reply): the hourly per-soul-per-channel cap,
# the per-thread cap that resets when Alex McRitchie writes, the release and
# owner-reply exemptions (counted, never suppressed), suppression that is
# recorded and never retried, and keyed posts that go out exactly once.
class MediaSlackLimitsTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  CHAN = "C0LIMITS01".freeze
  OWNER = "U0OWNER001".freeze
  ROOT = "1761900000.000100".freeze

  class FakeTransport
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = []
      @seq = 0
    end

    def call(method, params, _token)
      @calls << { method: method, params: params }
      answer = @answers.shift
      raise answer if answer.is_a?(Exception) || (answer.is_a?(Class) && answer <= Exception)
      return answer if answer

      @seq += 1
      [ 200, {}, { ok: true, channel: params[:channel], ts: "1761900001.#{format('%06d', @seq)}" }.to_json ]
    end
  end

  def limits(per_hour: 6, per_thread: 4, owner_count_only: true)
    Media::Slack::Limits.new({ "per_soul_per_channel_per_hour" => per_hour,
                               "replies_per_thread_without_owner" => per_thread,
                               "owner_replies_count_only" => owner_count_only }, owner_user_id: OWNER)
  end

  def adapter(transport, caps: limits)
    slack = Media::Slack.new(client: Media::Slack::Client.new(token: "xoxb-test", transport: transport))
    slack.instance_variable_set(:@limits, caps)
    slack
  end

  def home = Media::Home.new(medium: "slack", channel: "x", spec: { "id" => CHAN }, source: "test", fell_from: [])

  def posted!(soul:, thread_ts: nil, kind: "post", at: Time.current)
    SlackPost.create!(channel_id: CHAN, soul_slug: soul, thread_ts: thread_ts, kind: kind, status: "posted",
                      ts: "1.#{SecureRandom.hex(3)}", created_at: at)
  end

  def slack_row(soul: "avi", author_ref: "U0SOMEONE1", thread_ts: ROOT)
    agent_message!(soul: soul, status: "completed", channel: "slack", external_id: "#{CHAN}:#{SecureRandom.hex(4)}",
                   channel_ref: CHAN, thread_key: "slack:#{CHAN}:#{thread_ts}", author_ref: author_ref,
                   response_text: "An answer.", reply_status: "queued")
  end

  def owner_wrote!(at:)
    agent_message!(soul: "avi", status: "completed", channel: "slack", external_id: "#{CHAN}:#{SecureRandom.hex(4)}",
                   channel_ref: CHAN, thread_key: "slack:#{CHAN}:#{ROOT}", author_ref: OWNER, created_at: at)
  end

  # --- the counters ------------------------------------------------------------

  test "[unit] hourly cap: the soul's posts in this channel inside the hour count; older and other souls do not" do
    5.times { posted!(soul: "avi") }
    posted!(soul: "avi", at: 2.hours.ago)
    posted!(soul: "mason")

    assert_nil limits.refusal(channel_id: CHAN, soul: "avi", kind: "post")
    posted!(soul: "avi")
    reason = limits.refusal(channel_id: CHAN, soul: "avi", kind: "post")
    assert_match(/hourly cap: avi posted 6 times/, reason)
    assert_match(/per_soul_per_channel_per_hour/, reason)
  end

  test "[unit] release posts and answers to Alex McRitchie are exempt from the hourly cap, but counted" do
    6.times { posted!(soul: "avi", kind: "release") }

    assert_equal 6, limits.hourly_count(CHAN, "avi")
    assert_nil limits.refusal(channel_id: CHAN, soul: "avi", kind: "release")
    assert_nil limits.refusal(channel_id: CHAN, soul: "avi", kind: "reply", owner_reply: true)
    assert limits.refusal(channel_id: CHAN, soul: "avi", kind: "reply")
    assert limits(owner_count_only: false).refusal(channel_id: CHAN, soul: "avi", kind: "reply", owner_reply: true)
  end

  test "[unit] thread cap: agent posts since Alex McRitchie last wrote; his message resets it; nothing is exempt" do
    4.times { |i| posted!(soul: i.even? ? "avi" : "mason", thread_ts: ROOT, at: (10 - i).minutes.ago) }

    reason = limits.refusal(channel_id: CHAN, soul: "avi", kind: "release", thread_ts: ROOT)
    assert_match(/thread cap: 4 agent posts in this thread/, reason)

    owner_wrote!(at: 1.minute.ago)
    assert_nil limits.refusal(channel_id: CHAN, soul: "avi", kind: "release", thread_ts: ROOT)
    assert_equal 0, limits.thread_count(CHAN, ROOT)
  end

  test "[unit] a soul-less post is never capped; the defaults are 6 and 4" do
    10.times { posted!(soul: nil) }
    assert_nil limits(per_hour: 1).refusal(channel_id: CHAN, soul: nil, kind: "post")

    defaults = Media::Slack::Limits.new({})
    assert_equal [ 6, 4 ], [ defaults.per_hour, defaults.per_thread ]
  end

  test "[unit] the shipped config sets the caps Alex McRitchie chose and names his Slack id" do
    caps = Media::Slack::Limits.current(config: Media::Config.load)
    assert_equal [ 6, 4 ], [ caps.per_hour, caps.per_thread ]
    assert_equal "U0CCSMUMQJV", caps.owner_user_id
  end

  # --- the seam: #post ------------------------------------------------------------

  test "[unit] post over the cap sends nothing, records a suppressed row with the reason, and raises Suppressed" do
    6.times { posted!(soul: "avi") }
    transport = FakeTransport.new

    error = assert_raises(Media::Slack::Suppressed) { adapter(transport).post(home, text: "hi", soul: "avi") }
    assert_match(/hourly cap/, error.message)
    assert_empty transport.calls
    row = SlackPost.where(status: "suppressed").sole
    assert_equal [ CHAN, "avi", "post" ], [ row.channel_id, row.soul_slug, row.kind ]
    assert_match(/hourly cap/, row.reason)
  end

  test "[unit] post under the cap is ledgered as posted with Slack's ts; text passes a mention through untouched" do
    transport = FakeTransport.new
    answer = adapter(transport).post(home, text: ":red_circle: smoke red <@U0CCSMUMQJV>", soul: "avi", kind: "release",
                                           thread_ts: ROOT, release_slug: "rel-x")

    assert_equal ":red_circle: smoke red <@U0CCSMUMQJV>", transport.calls.sole[:params][:text]
    assert_equal ROOT, transport.calls.sole[:params][:thread_ts]
    row = SlackPost.sole
    assert_equal [ "posted", answer["ts"], "release", ROOT, "rel-x" ], [ row.status, row.ts, row.kind, row.thread_ts, row.release_slug ]
  end

  test "[unit] a keyed post goes out once: a re-run answers the first ts and sends nothing" do
    transport = FakeTransport.new
    slack = adapter(transport)
    first = slack.post(home, text: "one", soul: "mason", kind: "release", key: "release:rel-x:#{CHAN}:general")
    again = slack.post(home, text: "one", soul: "mason", kind: "release", key: "release:rel-x:#{CHAN}:general")

    assert_equal 1, transport.calls.size
    assert_equal first["ts"], again["ts"]
    assert again["already_posted"]
  end

  test "[unit] a keyed post that may have posted (ambiguous) is never sent again" do
    transport = FakeTransport.new(Net::ReadTimeout)
    slack = adapter(transport)
    key = "release:rel-x:#{CHAN}:app"
    assert_raises(Media::Slack::Ambiguous) { slack.post(home, text: "one", soul: "steffon", kind: "release", key: key) }
    assert SlackPost.find_by(idempotency_key: key).ambiguous?

    assert_raises(Media::Slack::Ambiguous) { slack.post(home, text: "one", soul: "steffon", kind: "release", key: key) }
    assert_equal 1, transport.calls.size
  end

  test "[unit] a keyed post Slack provably refused is tried again on the re-run" do
    transport = FakeTransport.new([ 200, {}, { ok: false, error: "not_in_channel" }.to_json ])
    slack = adapter(transport)
    key = "release:rel-x:#{CHAN}:app"
    assert_raises(Media::Slack::Refused) { slack.post(home, text: "one", soul: "steffon", kind: "release", key: key) }
    assert_equal "failed", SlackPost.find_by(idempotency_key: key).status

    slack.post(home, text: "one", soul: "steffon", kind: "release", key: key)
    assert_equal 2, transport.calls.size
    assert_equal "posted", SlackPost.find_by(idempotency_key: key).status
  end

  # --- the seam: #deliver_reply ---------------------------------------------------

  test "[unit] a reply over the thread cap is suppressed: skipped, a reply_suppressed event, and never retried" do
    4.times { posted!(soul: "avi", thread_ts: ROOT) }
    message = slack_row
    transport = FakeTransport.new

    assert_nil adapter(transport).deliver_reply(message)
    assert_empty transport.calls
    message.reload
    assert_equal "skipped", message.reply_status
    assert_match(/thread cap/, message.events.find_by(kind: "reply_suppressed").detail["reason"])
    assert_equal "suppressed", SlackPost.find_by(agent_message_id: message.id).status

    adapter(transport).deliver_reply(message)
    assert_empty transport.calls
    assert_equal 1, message.events.where(kind: "reply_suppressed").count
  end

  test "[unit] a posted reply is ledgered, so the next one counts it; Alex McRitchie's own question is answered over the hourly cap" do
    6.times { posted!(soul: "avi") }
    transport = FakeTransport.new
    capped = slack_row(thread_ts: "1761900000.000200")
    adapter(transport).deliver_reply(capped)
    assert_equal "skipped", capped.reload.reply_status

    his = slack_row(author_ref: OWNER, thread_ts: "1761900000.000300")
    adapter(transport).deliver_reply(his)
    assert_equal "posted", his.reload.reply_status
    assert_equal 1, transport.calls.size
    row = SlackPost.find_by(agent_message_id: his.id)
    assert_equal [ "posted", "reply", "1761900000.000300" ], [ row.status, row.kind, row.thread_ts ]
    assert_equal 7, limits.hourly_count(CHAN, "avi")
  end
end
