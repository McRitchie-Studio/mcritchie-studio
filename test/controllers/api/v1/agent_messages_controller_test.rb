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
        ray_message = agent_message!(soul: "ray")

        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "w" }, headers: bearer(studio_session("carl")), as: :json
        assert_response :forbidden
        assert_match(/cannot act for avi/, response.parsed_body["error"])

        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "w" }, headers: bearer(studio_session("avi")), as: :json
        assert_response :success
        assert_equal "avi", response.parsed_body.dig("data", "soul_slug")

        admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        post claim_api_v1_agent_messages_url, params: { soul: "ray", worker: "w" }, headers: bearer(admin), as: :json
        assert_response :success
        assert_equal ray_message.id, response.parsed_body.dig("data", "id")
        assert_equal "steffon", ray_message.reload.events.last.actor, "a session's soul is the recorded actor"
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
        agent_message!(soul: "ray")
        AgentMessage.claim!(soul: "avi", worker: "w1")

        get api_v1_agent_messages_url, params: { soul: "avi", status: "claimed" }, headers: @shared
        assert_response :success
        assert_equal [ avi.id ], response.parsed_body["data"].map { |m| m["id"] }

        get api_v1_agent_message_url(avi), headers: @shared
        assert_response :success
        assert_equal %w[claimed], response.parsed_body.dig("data", "events").map { |e| e["kind"] }
        assert_match %r{\Ahttps://discord.com/channels/}, response.parsed_body.dig("data", "url")
      end

      # --- long poll, renewal, refund (bin/dispatcher) -------------------------

      # Swaps the controller's sleep for a callable, so arrival and timeout are
      # decided by the test, not by wall-clock luck.
      def with_sleeper(callable)
        original = AgentMessagesController.long_poll_sleeper
        AgentMessagesController.long_poll_sleeper = callable
        yield
      ensure
        AgentMessagesController.long_poll_sleeper = original
      end

      test "a long-poll claim returns the message that arrives while it waits" do
        sleeps = []
        arrived = nil
        sleeper = lambda do |seconds|
          sleeps << seconds
          travel(seconds.seconds, with_usec: true)
          arrived ||= agent_message!(soul: "ray") if sleeps.size == 3
        end

        with_sleeper(sleeper) do
          post claim_api_v1_agent_messages_url, params: { souls: %w[avi ray], worker: "d1", wait: 15 },
                                                headers: @shared, as: :json
        end

        assert_response :success
        assert_equal arrived.id, response.parsed_body.dig("data", "id")
        assert_equal "d1", response.parsed_body.dig("data", "claimed_by")
        assert_equal 3, sleeps.size, "it answered on the first tick after the arrival"
        assert sleeps.all? { |s| s <= AgentMessagesController::POLL_INTERVAL }
      end

      test "a long-poll claim with nothing arriving answers data null at its deadline, and the wait is capped" do
        waited = 0.0
        with_sleeper(->(seconds) { waited += seconds; travel(seconds.seconds, with_usec: true) }) do
          post claim_api_v1_agent_messages_url, params: { souls: "avi,ray", worker: "d1", wait: 600 },
                                                headers: @shared, as: :json
        end

        assert_response :success
        assert_nil response.parsed_body["data"]
        assert_equal "nothing_waiting", response.parsed_body.dig("meta", "reason")
        assert_in_delta AgentMessagesController::WAIT_CAP, waited, 1.0
        assert_operator AgentMessagesController::WAIT_CAP, :<, 30, "under Heroku's 30-second router timeout"
      end

      test "a long poll waits in real time and times out empty (no stubbed clock)" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "d1", wait: 1 }, headers: @shared, as: :json
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_response :success
        assert_nil response.parsed_body["data"]
        assert_operator elapsed, :>=, 0.9
        assert_operator elapsed, :<, 5
      end

      test "a claim without wait does not sleep at all" do
        with_sleeper(->(_s) { flunk "a plain claim must not wait" }) do
          post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "d1" }, headers: @shared, as: :json
        end
        assert_response :success
        assert_nil response.parsed_body["data"]
      end

      test "a session may claim for several souls only if it may act for each" do
        agent_message!(soul: "carl")
        post claim_api_v1_agent_messages_url, params: { souls: %w[carl avi], worker: "w" },
                                              headers: bearer(studio_session("carl")), as: :json
        assert_response :forbidden
        assert_match(/cannot act for avi/, response.parsed_body["error"])

        admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        post claim_api_v1_agent_messages_url, params: { souls: %w[carl avi], worker: "w" }, headers: bearer(admin), as: :json
        assert_response :success
        assert_equal "carl", response.parsed_body.dig("data", "soul_slug")
      end

      test "renew extends the holder's lease and is refused (409) to anyone else" do
        message = agent_message!
        AgentMessage.claim!(soul: "avi", worker: "d1", now: 4.minutes.ago)
        before = message.reload.lease_expires_at

        post renew_api_v1_agent_message_url(message), params: { worker: "d2" }, headers: @shared, as: :json
        assert_response :conflict
        assert_equal "NOT_HOLDER", response.parsed_body["error_code"]

        post renew_api_v1_agent_message_url(message), params: { worker: "d1" }, headers: @shared, as: :json
        assert_response :success
        assert_operator message.reload.lease_expires_at, :>, before
        assert_equal "lease_renewed", message.events.last.kind
      end

      test "a non-admin session cannot renew another soul's message" do
        message = agent_message!(soul: "avi")
        AgentMessage.claim!(soul: "avi", worker: "d1")

        post renew_api_v1_agent_message_url(message), params: { worker: "d1" },
                                                      headers: bearer(studio_session("carl")), as: :json
        assert_response :forbidden
      end

      test "release with code usage_limit refunds the attempt over HTTP; an unknown code is a 422" do
        message = agent_message!
        AgentMessage.claim!(soul: "avi", worker: "d1")

        post release_api_v1_agent_message_url(message), params: { worker: "d1", code: "nope" }, headers: @shared, as: :json
        assert_response :unprocessable_entity
        assert_equal "UNKNOWN_CODE", response.parsed_body["error_code"]

        post release_api_v1_agent_message_url(message), params: { worker: "d1", reason: "limit", code: "usage_limit" },
                                                        headers: @shared, as: :json
        assert_response :success
        assert_equal "received", response.parsed_body.dig("data", "status")
        assert_equal 0, response.parsed_body.dig("data", "attempts")
      end

      test "over HTTP, usage_limit refunds stop at the cap and the message dead-letters" do
        message = agent_message!
        statuses = (AgentMessage::MAX_REFUNDS + AgentMessage::MAX_ATTEMPTS).times.map do
          post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "d1" }, headers: @shared, as: :json
          post release_api_v1_agent_message_url(message), params: { worker: "d1", code: "usage_limit" },
                                                          headers: @shared, as: :json
          assert_response :success
          response.parsed_body.dig("data", "status")
        end

        assert_equal "dead", statuses.last
        assert_equal AgentMessage::MAX_REFUNDS, message.reload.usage_refunds
      end

      # --- typing (bin/dispatcher's pulse) -----------------------------------

      test "typing queues one pulse for the holder, 409s anyone else, and says capped past the cap" do
        message = agent_message!
        post claim_api_v1_agent_messages_url, params: { soul: "avi", worker: "d1" }, headers: @shared, as: :json

        assert_enqueued_with(job: AgentMessageTypingJob, args: [ message.id, "d1" ]) do
          post typing_api_v1_agent_message_url(message), params: { worker: "d1" }, headers: @shared, as: :json
        end
        assert_response :success
        assert_equal "queued", response.parsed_body.dig("meta", "typing")

        assert_no_enqueued_jobs(only: AgentMessageTypingJob) do
          post typing_api_v1_agent_message_url(message), params: { worker: "d2" }, headers: @shared, as: :json
        end
        assert_response :conflict
        assert_equal "NOT_HOLDER", response.parsed_body["error_code"]

        travel_to(message.reload.claimed_at + AgentMessage::TYPING_CAP + 1) do
          assert_no_enqueued_jobs(only: AgentMessageTypingJob) do
            post typing_api_v1_agent_message_url(message), params: { worker: "d1" }, headers: @shared, as: :json
          end
        end
        assert_response :success
        assert_equal "capped", response.parsed_body.dig("meta", "typing")
      end

      test "typing for a message nobody claimed is refused and queues nothing" do
        message = agent_message!
        assert_no_enqueued_jobs(only: AgentMessageTypingJob) do
          post typing_api_v1_agent_message_url(message), params: { worker: "d1" }, headers: @shared, as: :json
        end
        assert_response :conflict
      end
    end
  end
end
