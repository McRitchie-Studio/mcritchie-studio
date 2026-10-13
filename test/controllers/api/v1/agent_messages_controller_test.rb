require "test_helper"
require_relative "../../../support/agent_message_fixtures"

module Api
  module V1
    # [integration] The agent mailbox API: the board's own auth, the soul scope a
    # session carries, the always-200 claim, complete-once over HTTP, release,
    # and the reads bin/agent-inbox makes.
    class AgentMessagesControllerTest < ActionDispatch::IntegrationTest
      include AgentMessageFixtures

      setup do
        token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
        @shared = { "Authorization" => "Bearer #{token}" }
      end

      def bearer(session) = { "Authorization" => "Bearer #{session.token}" }

      def studio_session(soul)
        task = Task.create!(title: "Mailbox Session #{soul}", slug: "mailbox-session-#{soul}", stage: "building")
        AgentSession.create!(soul: soul, tier: "studio", issued_by: "task_claim", task_slug: task.slug)
      end

      test "every route needs a bearer token" do
        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "w" }, as: :json
        assert_response :unauthorized
        get api_v1_agent_messages_url
        assert_response :unauthorized
      end

      test "claim hands out one message with a lease, then answers an empty 200" do
        message = agent_message!

        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "laptop-1" }, headers: @shared, as: :json
        assert_response :success
        body = response.parsed_body
        assert_equal message.id, body.dig("data", "id")
        assert_equal "claimed", body.dig("data", "status")
        assert_equal "laptop-1", body.dig("data", "claimed_by")
        assert_equal "claimed", body.dig("meta", "reason")

        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "laptop-2" }, headers: @shared, as: :json
        assert_response :success
        assert_nil response.parsed_body["data"]
        assert_equal "nothing_waiting", response.parsed_body.dig("meta", "reason")
      end

      test "a claim without a worker is refused, and logs no error" do
        assert_no_difference -> { ErrorLog.count } do
          post claim_api_v1_agent_messages_url, params: { soul: "avi" }, headers: @shared, as: :json
        end
        assert_response :unprocessable_entity
        assert_equal "WORKER_REQUIRED", response.parsed_body["error_code"]
      end

      test "a session acts only for its own soul; an admin session for any" do
        agent_message!(soul: "avi")
        xan_message = agent_message!(soul: "xan")

        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "w" }, headers: bearer(studio_session("carl")), as: :json
        assert_response :forbidden
        assert_match(/cannot act for avi/, response.parsed_body["error"])

        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "w" }, headers: bearer(studio_session("avi")), as: :json
        assert_response :success
        assert_equal "avi", response.parsed_body.dig("data", "soul_slug")

        admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        post claim_api_v1_agent_messages_url, params: { soul: "xan", worker: "w" }, headers: bearer(admin), as: :json
        assert_response :success
        assert_equal xan_message.id, response.parsed_body.dig("data", "id")
        assert_equal "steffon", xan_message.reload.events.last.actor, "a session's soul is the recorded actor"
      end

      test "a harness key reaches none of the mailbox" do
        key = AgentSession.create!(soul: "pokemon", tier: "harness", issued_by: "operator_grant", label: "test-mac")
        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "w" }, headers: bearer(key), as: :json
        assert_response :forbidden
      end

      test "complete twice over HTTP completes once and queues one reply; a stranger gets 409" do
        message = agent_message!
        AgentMessage.claim!(soul: "avi", worker: "w1")

        post complete_api_v1_agent_message_url(message), params: { worker: "w2", response_text: "x" }, headers: @shared, as: :json
        assert_response :conflict
        assert_equal "NOT_HOLDER", response.parsed_body["error_code"]

        assert_enqueued_jobs 1, only: AgentMessageReplyJob do
          2.times do
            post complete_api_v1_agent_message_url(message),
                 params: { worker: "w1", response_text: "Release is green.", action_summary: "ran bin/release status" },
                 headers: @shared, as: :json
            assert_response :success
          end
        end
        assert_equal "already_completed", response.parsed_body.dig("meta", "outcome")
        assert_equal "completed", message.reload.status
        assert_equal "ran bin/release status", message.action_summary
      end

      test "release gives a claim back to the queue" do
        message = agent_message!
        AgentMessage.claim!(soul: "avi", worker: "w1")

        post release_api_v1_agent_message_url(message), params: { worker: "w1", reason: "claude timed out" }, headers: @shared, as: :json
        assert_response :success
        assert_equal "received", response.parsed_body.dig("data", "status")
      end

      test "next shows what a claim would take, and writes nothing" do
        message = agent_message!
        get next_api_v1_agent_messages_url, params: { soul: "avi" }, headers: @shared
        assert_response :success
        assert_equal message.id, response.parsed_body.dig("data", "id")
        assert_equal "received", message.reload.status
        assert_equal 0, message.events.count
      end

      test "list filters by soul and status, and show carries the timeline" do
        avi = agent_message!(soul: "avi")
        agent_message!(soul: "xan")
        AgentMessage.claim!(soul: "avi", worker: "w1")

        get api_v1_agent_messages_url, params: { soul: "avi", status: "claimed" }, headers: @shared
        assert_response :success
        assert_equal [ avi.id ], response.parsed_body["data"].map { |m| m["id"] }

        get api_v1_agent_message_url(avi), headers: @shared
        assert_response :success
        assert_equal %w[claimed], response.parsed_body.dig("data", "events").map { |e| e["kind"] }
        assert_match %r{\Ahttps://discord.com/channels/}, response.parsed_body.dig("data", "url")
      end
    end
  end
end
