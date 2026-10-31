require "test_helper"
require_relative "../support/agent_message_fixtures"
require_relative "../support/teams_fixtures"

# [integration] The Teams loop end to end, the Bot Connector stubbed and the
# Bot Framework JWKS local: a JWT-signed activity at POST
# /webhooks/teams/messages → TeamsIngestJob → an agent_messages row → claimed
# and completed as the dispatcher would → AgentMessageReplyJob → Media::Teams
# replies in the message's channel thread with an Adaptive Card headed with
# the soul. And the endpoint's guard: no credentials is a 503, and a missing,
# mis-signed or mis-addressed token is a 401 that enqueues nothing.
class TeamsMessagesLoopTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include AgentMessageFixtures
  include TeamsFixtures

  ENVS = { "TEAMS_BOT_APP_ID" => APP_ID, "TEAMS_BOT_APP_PASSWORD" => "secret-pw", "TEAMS_TENANT_ID" => TENANT }.freeze

  setup do
    @envs_were = ENVS.keys.to_h { |k| [ k, ENV[k] ] }
    ENVS.each { |k, v| ENV[k] = v }
    AgentMessages::TeamsRoutes.current = teams_routes
    cache = AgentMessages::TeamsAuth.key_cache
    cache.reset!
    cache.keys = { KID => teams_jwk }
    cache.fetched_at = Time.current
    cache.refetched_at = Time.current # an unknown kid must not reach the network
  end

  teardown do
    @envs_were.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    AgentMessages::TeamsRoutes.reset!
    AgentMessages::TeamsAuth.key_cache.reset!
  end

  def deliver(activity, token: teams_token)
    post "/webhooks/teams/messages", params: activity.to_json,
                                     headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{token}" }.compact
  end

  test "[integration] with no credentials the endpoint answers 503 and enqueues nothing" do
    ENV.delete("TEAMS_BOT_APP_PASSWORD")
    assert_no_enqueued_jobs do
      deliver(teams_activity)
    end
    assert_response :service_unavailable
  end

  test "[integration] a missing, mis-signed, wrong-audience, expired or serviceUrl-mismatched token is a 401 and enqueues nothing" do
    assert_no_enqueued_jobs do
      post "/webhooks/teams/messages", params: teams_activity.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :unauthorized
      deliver(teams_activity, token: teams_token(key: TeamsFixtures.other_key))
      assert_response :unauthorized
      deliver(teams_activity, token: teams_token(aud: "another-bot"))
      assert_response :unauthorized
      deliver(teams_activity, token: teams_token(exp: 10.minutes.ago))
      assert_response :unauthorized
      deliver(teams_activity, token: teams_token(service_url: "https://smba.trafficmanager.net/emea/"))
      assert_response :unauthorized
      deliver(teams_activity, token: teams_token(kid: "unknown"))
      assert_response :unauthorized
    end
    post "/webhooks/teams/messages", params: "not json", headers: { "CONTENT_TYPE" => "application/json",
                                                                   "Authorization" => "Bearer #{teams_token}" }
    assert_response :bad_request
  end

  test "[integration] the install event is acked and stores the conversation reference" do
    deliver(teams_install_activity)
    assert_response :ok
    perform_enqueued_jobs(only: TeamsIngestJob)

    assert TeamsConversation.installed.exists?(conversation_id: CHANNEL, service_url: SERVICE_URL)
  end

  test "[integration] the whole loop: a Teams message to Avi is stored for the owner, answered, and replied in its thread as an Avi card" do
    AgentMessages::Answerers.reset! # the real owner-only guard: the owner's Entra id must be linked
    owner = AgentPerson.seed_owner!
    activity = teams_activity(text: "Avi, is the release green?", id: "1761900000001", from_aad: OWNER_AAD, mention_bot: true)
    assert_enqueued_with(job: TeamsIngestJob) { deliver(activity) }
    assert_response :ok
    perform_enqueued_jobs(only: TeamsIngestJob)

    row = AgentMessage.find_by!(channel: "teams", external_id: "#{CHANNEL}:1761900000001")
    assert_equal [ "avi", "name", "received", owner.id ], [ row.soul_slug, row.routed_by, row.status, row.person_id ]

    deliver(activity) # the Bot Framework's retry
    assert_no_difference -> { AgentMessage.count } do
      perform_enqueued_jobs(only: TeamsIngestJob)
    end

    claimed = AgentMessage.claim!(soul: %w[avi alex], worker: "dispatcher-test")
    assert_equal row.id, claimed.message.id
    row.reload.complete!(worker: "dispatcher-test", response_text: "**Green.** QA passed.")

    calls = []
    transport = lambda do |_method, url, _headers, body|
      next [ 200, {}, { access_token: "tok", expires_in: 3600 }.to_json ] if url.include?("login.microsoftonline.com")

      calls << [ url, JSON.parse(body) ]
      [ 201, {}, { id: "1761900005009" }.to_json ]
    end
    client = Media::Teams::Client.new(transport: transport, token_cache: Media::Teams::Client::TokenCache.new)
    Media::Teams::Client.stub(:new, ->(*, **) { client }) do
      perform_enqueued_jobs(only: AgentMessageReplyJob)
    end

    url, body = calls.sole
    assert url.end_with?("/v3/conversations/#{ERB::Util.url_encode("#{CHANNEL};messageid=1761900000001")}/activities/1761900000001")
    assert_equal "1761900000001", body["replyToId"]
    card = body["attachments"].sole["content"]
    assert_equal "AdaptiveCard", card["type"]
    header = card["body"].first["columns"]
    assert_match %r{\Ahttps://.+/slack-icons/avi\.png\z}, header.first["items"].sole["url"]
    assert_equal "Avi", header.last["items"].sole["text"]
    assert_equal "**Green.** QA passed.", card["body"].second["text"]
    row.reload
    assert_equal [ "posted", "1761900005009" ], [ row.reply_status, row.reply_external_id ]
  end
end
