require "test_helper"
require_relative "../support/agent_message_fixtures"

# [integration] The Slack loop end to end, Slack's HTTP stubbed: a signed
# event at POST /webhooks/slack/events → SlackIngestJob → an agent_messages row
# → claimed and completed as the dispatcher would → AgentMessageReplyJob →
# Media::Slack posts the answer as the soul, in the message's thread. And the
# endpoint's guard: unsigned, mis-signed and stale requests enqueue nothing;
# the url_verification challenge is answered only when signed.
class SlackEventsLoopTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include AgentMessageFixtures

  SECRET = "test-slack-signing-secret".freeze
  TEAM = "T0CC9DQ9NAK".freeze      # the shipped slack.team_id
  AGENTS = "C0CD8ETBZBM".freeze    # #agents
  OWNER = "U0CCSMUMQJV".freeze     # Alex McRitchie (slack.owner_user_id)
  APP_BOT = "U0CE93ACBA4".freeze   # McRitchie Agents

  setup do
    AgentMessages::SlackRoutes.reset!
    @secret_was = ENV["SLACK_SIGNING_SECRET"]
    ENV["SLACK_SIGNING_SECRET"] = SECRET
  end

  teardown do
    @secret_was ? ENV["SLACK_SIGNING_SECRET"] = @secret_was : ENV.delete("SLACK_SIGNING_SECRET")
  end

  def headers(body, timestamp: Time.current.to_i, secret: SECRET)
    sig = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
    { "X-Slack-Request-Timestamp" => timestamp.to_s, "X-Slack-Signature" => sig, "CONTENT_TYPE" => "application/json" }
  end

  def callback(event, event_id: "Ev#{rand(1_000_000)}")
    { token: "unused", team_id: TEAM, api_app_id: "A0CDCN1Q9AS", type: "event_callback", event_id: event_id,
      event_time: Time.current.to_i, event: event }.to_json
  end

  def message_event(text, ts: "1761800000.000100", **extra)
    { type: "message", channel: AGENTS, channel_type: "channel", user: OWNER, text: text, ts: ts }.merge(extra)
  end

  test "[integration] url_verification: the challenge is echoed only on a signed request" do
    body = { type: "url_verification", challenge: "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P", token: "x" }.to_json
    post "/webhooks/slack/events", params: body, headers: headers(body)
    assert_response :success
    assert_equal "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P", response.parsed_body["challenge"]

    post "/webhooks/slack/events", params: body, headers: headers(body, secret: "wrong")
    assert_response :unauthorized
  end

  test "[integration] an unsigned, mis-signed, stale or unconfigured request is a 401 and enqueues nothing" do
    body = callback(message_event("Avi, hi"))
    assert_no_enqueued_jobs do
      post "/webhooks/slack/events", params: body, headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :unauthorized
      post "/webhooks/slack/events", params: body, headers: headers(body, secret: "wrong")
      assert_response :unauthorized
      post "/webhooks/slack/events", params: body, headers: headers(body, timestamp: 6.minutes.ago.to_i)
      assert_response :unauthorized
      tampered = body.sub("Avi, hi", "Avi, rm")
      post "/webhooks/slack/events", params: tampered, headers: headers(body)
      assert_response :unauthorized
      ENV.delete("SLACK_SIGNING_SECRET")
      post "/webhooks/slack/events", params: body, headers: headers(body)
      assert_response :unauthorized
    end
  end

  test "[integration] a signed event is acked at once and ingested by the job; a retried delivery stores nothing new" do
    AgentPerson.seed_owner!
    body = callback(message_event("Avi, what shipped today?"), event_id: "Ev1")
    assert_enqueued_with(job: SlackIngestJob) do
      post "/webhooks/slack/events", params: body, headers: headers(body)
    end
    assert_response :ok
    assert_difference -> { AgentMessage.count }, 1 do
      perform_enqueued_jobs(only: SlackIngestJob)
    end

    retry_body = callback(message_event("Avi, what shipped today?"), event_id: "Ev1")
    post "/webhooks/slack/events", params: retry_body, headers: headers(retry_body).merge("X-Slack-Retry-Num" => "1")
    assert_response :ok
    assert_no_difference -> { AgentMessage.count } do
      perform_enqueued_jobs(only: SlackIngestJob)
    end
  end

  test "[integration] the whole loop: a Slack message to Avi is stored for the owner, answered, and replied in its thread as Avi" do
    AgentMessages::Answerers.reset! # the real owner-only guard: the owner's Slack user must be linked
    owner = AgentPerson.seed_owner!
    body = callback(message_event("<@#{APP_BOT}> Avi, is the release green?", ts: "1761800000.000100"))
    post "/webhooks/slack/events", params: body, headers: headers(body)
    assert_response :ok
    perform_enqueued_jobs(only: SlackIngestJob)

    row = AgentMessage.find_by!(channel: "slack", external_id: "#{AGENTS}:1761800000.000100")
    assert_equal [ "avi", "name", "received", owner.id ], [ row.soul_slug, row.routed_by, row.status, row.person_id ]
    assert_equal [ TEAM, AGENTS, "slack:#{AGENTS}:1761800000.000100" ], [ row.guild_id, row.channel_ref, row.thread_key ]

    claimed = AgentMessage.claim!(soul: %w[avi alex], worker: "dispatcher-test")
    assert_equal row.id, claimed.message.id, "the owner's Slack message is claimable"
    row.reload.complete!(worker: "dispatcher-test", response_text: "**Green.** QA passed.")

    calls = []
    transport = lambda do |method, params, _token|
      calls << [ method, params ]
      [ 200, {}, { ok: true, channel: AGENTS, ts: "1761800005.000900" }.to_json ]
    end
    client = Media::Slack::Client.new(token: "xoxb-test", transport: transport)
    with_env("SLACK_BOT_TOKEN", "xoxb-test") do
      Media::Slack::Client.stub(:new, ->(*, **) { client }) do
        perform_enqueued_jobs(only: AgentMessageReplyJob)
      end
    end

    method, params = calls.sole
    assert_equal "chat.postMessage", method
    assert_equal [ AGENTS, "1761800000.000100", "Avi", "*Green.* QA passed." ], params.values_at(:channel, :thread_ts, :username, :text)
    assert_match %r{\Ahttps://.+/slack-icons/avi\.png\z}, params[:icon_url]
    row.reload
    assert_equal [ "posted", "1761800005.000900" ], [ row.reply_status, row.reply_external_id ]

    # Our own customized post comes back as an event: never ingested.
    echo = callback(message_event("Green. QA passed.", ts: "1761800005.000900", thread_ts: "1761800000.000100",
                                  bot_id: "B0CD8EZFSPM", user: APP_BOT, subtype: "bot_message"))
    post "/webhooks/slack/events", params: echo, headers: headers(echo)
    assert_no_difference -> { AgentMessage.count } do
      perform_enqueued_jobs(only: SlackIngestJob)
    end

    # The owner's follow-up in the thread is Avi's, in the same conversation.
    follow = callback(message_event("thanks, and turf?", ts: "1761800009.000100", thread_ts: "1761800000.000100"))
    post "/webhooks/slack/events", params: follow, headers: headers(follow)
    perform_enqueued_jobs(only: SlackIngestJob)
    second = AgentMessage.find_by!(external_id: "#{AGENTS}:1761800009.000100")
    assert_equal [ "avi", "thread", row.thread_key ], [ second.soul_slug, second.routed_by, second.thread_key ]
  end
end
