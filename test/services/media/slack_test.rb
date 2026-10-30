require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] Media::Slack with a stubbed transport: a post carries the soul's
# username and absolute portrait and the thread's root ts; the client sorts
# every outcome into posted / NotPosted / Refused / Ambiguous; deliver_reply
# locks the row, retries only a provable non-post, never blind-retries an
# ambiguous one, and leaves a live attempt alone; Format converts Discord
# Markdown and embeds; the one-line release_notes flip.
class MediaSlackTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include ActiveJob::TestHelper

  CHAN = "C0AGENTS01".freeze

  # A transport double: answers queued [status, headers, body] (or raises a
  # queued exception) and records every call.
  class FakeTransport
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = []
    end

    def call(method, params, token)
      @calls << { method: method, params: params, token: token }
      answer = @answers.shift || ok
      raise answer if answer.is_a?(Exception) || (answer.is_a?(Class) && answer <= Exception)

      answer
    end

    def ok(ts = "1761800001.000200") = [ 200, {}, { ok: true, channel: CHAN, ts: ts }.to_json ]
  end

  def ok(ts = "1761800001.000200") = [ 200, {}, { ok: true, channel: CHAN, ts: ts }.to_json ]
  def slack_error(error) = [ 200, {}, { ok: false, error: error }.to_json ]

  def adapter(transport, token: "xoxb-test")
    Media::Slack.new(client: Media::Slack::Client.new(token: token, transport: transport))
  end

  def slack_row(soul: "avi", status: "completed", response: "**Done.** See [the board](https://mcritchie.studio/tasks)")
    root = "1761800000.000100"
    agent_message!(soul: soul, status: status, channel: "slack", external_id: "#{CHAN}:1761800000.000300",
                   guild_id: "T0TEST0001", channel_ref: CHAN, thread_key: "slack:#{CHAN}:#{root}",
                   response_text: response)
  end

  test "[unit] post identity and thread: one chat.postMessage as the soul, in the thread's root, mrkdwn text" do
    transport = FakeTransport.new(ok)
    message = slack_row
    adapter(transport).deliver_reply(message)

    call = transport.calls.sole
    assert_equal "chat.postMessage", call[:method]
    assert_equal "xoxb-test", call[:token]
    params = call[:params]
    assert_equal [ CHAN, "1761800000.000100", "Avi" ], params.values_at(:channel, :thread_ts, :username)
    assert_equal "https://mcritchie.studio/agents/slack/avi.png", params[:icon_url], "an absolute public URL"
    assert_equal "*Done.* See <https://mcritchie.studio/tasks|the board>", params[:text]

    message.reload
    assert_equal [ "posted", "1761800001.000200" ], [ message.reply_status, message.reply_external_id ]
    assert_equal "https://slack.com/archives/#{CHAN}/p1761800001000200", message.reply_url
    assert_equal %w[reply_sending reply_posted], message.events.map(&:kind)
  end

  test "[unit] identity_for: display name from the registry, portrait from agent_media.yml or the PNG beside souls.yml's avatar" do
    slack = Media::Slack.new(client: Media::Slack::Client.new(token: ""))
    assert_equal({ username: "Turf", icon_url: "https://mcritchie.studio/agents/slack/turf-monster.png" }, slack.identity_for("turf_monster"))
    custom = Media::Slack.new(config: Media::Config.new("souls" => { "avi" => { "icon" => "https://cdn.example/avi.png" } }))
    assert_equal "https://cdn.example/avi.png", custom.identity_for("avi")[:icon_url]
    assert_nil slack.identity_for("nobody_at_all")[:icon_url], "no portrait: Slack shows the app's own"
  end

  test "[unit] capabilities: reply always (it records the skip); post only while SLACK_BOT_TOKEN is set; never typing" do
    assert_equal %i[reply], adapter(FakeTransport.new, token: "").capabilities
    assert_equal %i[reply post], adapter(FakeTransport.new).capabilities
    refute_includes AgentMessage::TYPING_CHANNELS, "slack"
  end

  test "[unit] with no token the reply is skipped and recorded, nothing is sent" do
    transport = FakeTransport.new
    message = slack_row
    adapter(transport, token: "").deliver_reply(message)
    assert_empty transport.calls
    assert_equal "skipped", message.reload.reply_status
    assert_includes message.events.last.detail["reason"], "SLACK_BOT_TOKEN"
  end

  test "[unit] retry policy: the client sorts every outcome; only NotPosted is a retryable non-post" do
    {
      [ 429, { "Retry-After" => "7" }, "" ] => [ Media::Slack::NotPosted, "ratelimited" ],
      slack_error("ratelimited") => [ Media::Slack::NotPosted, "ratelimited" ],
      slack_error("service_unavailable") => [ Media::Slack::NotPosted, "service_unavailable" ],
      slack_error("channel_not_found") => [ Media::Slack::Refused, "channel_not_found" ],
      slack_error("not_in_channel") => [ Media::Slack::Refused, "not_in_channel" ],
      slack_error("invalid_auth") => [ Media::Slack::Refused, "invalid_auth" ],
      slack_error("fatal_error") => [ Media::Slack::Ambiguous, "fatal_error" ],
      slack_error("internal_error") => [ Media::Slack::Ambiguous, "internal_error" ],
      [ 502, {}, "bad gateway" ] => [ Media::Slack::Ambiguous, "http_502" ],
      [ 200, {}, "<html>" ] => [ Media::Slack::Ambiguous, "unreadable" ],
      Net::ReadTimeout.new => [ Media::Slack::Ambiguous, "timeout" ],
      Errno::ECONNRESET.new => [ Media::Slack::Ambiguous, "timeout" ],
      Net::OpenTimeout.new => [ Media::Slack::NotPosted, "unreachable" ],
      SocketError.new("getaddrinfo") => [ Media::Slack::NotPosted, "unreachable" ]
    }.each do |answer, (klass, code)|
      client = Media::Slack::Client.new(token: "xoxb-test", transport: FakeTransport.new(answer))
      error = assert_raises(klass, "#{answer.inspect} is #{klass}") { client.post_message(channel: CHAN, text: "x") }
      assert_equal code, error.code
      assert_kind_of Media::Error, error
      refute_includes error.message, "xoxb-test", "the token never reaches an error"
    end
    error = assert_raises(Media::Slack::NotPosted) do
      Media::Slack::Client.new(token: "t", transport: FakeTransport.new([ 429, { "retry-after" => "7" }, "" ])).post_message({})
    end
    assert_in_delta 7.0, error.retry_after
  end

  test "[unit] deliver_reply: a provable non-post is recorded and raised, so the reply job retries it, then posts once" do
    transport = FakeTransport.new([ 429, { "Retry-After" => "1" }, "" ], ok)
    message = slack_row
    slack = adapter(transport)
    assert_raises(Media::Slack::NotPosted) { slack.deliver_reply(message) }
    assert_equal %w[reply_sending reply_not_posted], message.events.reload.map(&:kind)
    assert_nil message.reload.reply_external_id

    slack.deliver_reply(message)
    assert_equal "posted", message.reload.reply_status
    assert_equal 2, transport.calls.size
    assert_equal 2, message.events.where(kind: "reply_sending").count
  end

  test "[unit] deliver_reply: the reply job's retry_on Media::Error retries a NotPosted, and the retry posts" do
    transport = FakeTransport.new(slack_error("ratelimited"), ok)
    message = slack_row
    Media.stub(:adapter, ->(key) { key.to_s == "slack" ? adapter(transport) : Media::Discord.new }) do
      Media.stub(:supports?, true) do
        assert_enqueued_jobs 1, only: AgentMessageReplyJob do
          AgentMessageReplyJob.perform_now(message.id)
        end
        AgentMessageReplyJob.perform_now(message.id)
      end
    end
    assert_equal "posted", message.reload.reply_status
  end

  test "[unit] deliver_reply: a refusal fails the reply without a retry" do
    transport = FakeTransport.new(slack_error("not_in_channel"))
    message = slack_row
    assert_nil adapter(transport).deliver_reply(message)
    assert_equal "failed", message.reload.reply_status
    assert_includes message.events.last.detail["error"], "not_in_channel"
    adapter(transport).deliver_reply(message)
    assert_equal 1, transport.calls.size, "a failed row is never posted again"
  end

  test "[unit] deliver_reply: a timeout is ambiguous: failed, flagged, and NEVER blind-retried" do
    transport = FakeTransport.new(Net::ReadTimeout.new)
    message = slack_row
    assert_nil adapter(transport).deliver_reply(message)
    assert_equal "failed", message.reload.reply_status
    assert_equal true, message.events.last.detail["ambiguous"]
    adapter(transport).deliver_reply(message)
    assert_equal 1, transport.calls.size
  end

  test "[unit] the row lock: a live attempt is left alone; a crashed one (stale reply_sending) is failed, not re-posted" do
    transport = FakeTransport.new
    message = slack_row
    message.record!("reply_sending", actor: "slack-bot", detail: { "attempt" => 1 })
    assert_nil adapter(transport).deliver_reply(message)
    assert_empty transport.calls, "an attempt in flight: no second post"
    assert_equal "completed", message.reload.status
    assert_nil message.reply_status

    message.events.where(kind: "reply_sending").update_all(created_at: 3.minutes.ago)
    adapter(transport).deliver_reply(message)
    assert_empty transport.calls, "a crashed attempt may have posted: never re-posted"
    assert_equal "failed", message.reload.reply_status
    assert_equal true, message.events.last.detail["ambiguous"]
  end

  test "[unit] a posted row is never posted again" do
    transport = FakeTransport.new
    message = slack_row
    message.update!(reply_external_id: "1761800001.000200", reply_status: "posted")
    adapter(transport).deliver_reply(message)
    assert_empty transport.calls
  end

  test "[unit] Format: Markdown to mrkdwn, and Discord embeds to minimal Block Kit under Slack's limits" do
    assert_equal "*bold* _it_ ~gone~ <https://x.test/a?b=1&amp;c=2|link> &lt;tag&gt;",
                 Media::Slack::Format.mrkdwn("**bold** __it__ ~~gone~~ [link](https://x.test/a?b=1&c=2) <tag>")
    assert_equal "*Heading*\nbody", Media::Slack::Format.mrkdwn("## Heading\nbody")

    embeds = [ { title: "Ship it", url: "https://mcritchie.studio/tasks/x", description: "**fast**",
                 fields: [ { name: "Repo", value: "hub" } ], footer: { text: "epic" } } ]
    message = Media::Slack::Format.messages(content: "🚀 Production deployed", embeds: embeds).sole
    assert_equal "🚀 Production deployed", message[:text]
    assert_equal %w[section divider section section context], message[:blocks].map { |b| b[:type] }
    assert_equal "*<https://mcritchie.studio/tasks/x|Ship it>*\n*fast*", message[:blocks][2][:text][:text]
    assert_equal "*Repo*\nhub", message[:blocks][3][:fields].sole[:text]

    many = Media::Slack::Format.messages(content: "x", embeds: Array.new(30) { |i| { title: "Task #{i}" } })
    assert_operator many.size, :>, 1
    assert(many.all? { |m| m[:blocks].size <= Media::Slack::Format::BLOCKS_PER_MESSAGE })
    long = Media::Slack::Format.messages(content: "a\n" * 4000, embeds: [ { title: "t" } ]).first
    assert(long[:blocks].all? { |b| b.dig(:text, :text).to_s.length <= Media::Slack::Format::SECTION_LIMIT })
    assert_empty Media::Slack::Format.messages(content: " ")
  end

  test "[unit] Media.post to a Slack home: the channel id, Block Kit from embeds, no soul identity unless asked" do
    transport = FakeTransport.new(ok)
    home = Media::Home.new(medium: "slack", channel: "releases", spec: { "id" => "C0CDJCN4L92" }, source: "purpose:release_notes", fell_from: [])
    adapter(transport).post(home, content: "🚀 deployed", embeds: [ { title: "Task" } ])
    params = transport.calls.sole[:params]
    assert_equal "C0CDJCN4L92", params[:channel]
    assert params[:blocks].present?
    refute params.key?(:username)
  end

  test "[unit] release_notes flips to Slack by ONE line, and falls back to Discord while SLACK_BOT_TOKEN is unset" do
    shipped = YAML.safe_load_file(Media::Config::PATH)
    assert_equal "discord", shipped.dig("purposes", "release_notes", "medium"), "the shipped file keeps it on Discord"
    flipped = Media::Config.new(shipped.deep_merge("purposes" => { "release_notes" => { "medium" => "slack" } }))
    Media.reset_fallback_notes!

    with_env("SLACK_BOT_TOKEN", "xoxb-test") do
      home = Media.home(purpose: :release_notes, config: flipped)
      assert_equal [ "slack", "releases", "C0CDJCN4L92" ], [ home.medium, home.channel, home.channel_id ]
    end
    with_env("SLACK_BOT_TOKEN", nil) do
      home = Media.home(purpose: :release_notes, config: flipped)
      assert_equal [ "discord", [ "slack" ] ], [ home.medium, home.fell_from ], "a half-set Slack never silences the post"
    end
  end
end
