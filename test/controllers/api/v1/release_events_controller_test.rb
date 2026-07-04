require "test_helper"

module Api
  module V1
    class ReleaseEventsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @release = Release.open!
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "start records a release event without usage" do
        assert_difference -> { ReleaseEvent.count }, 1 do
          post "/api/v1/releases/#{@release.slug}/events/ship_gate/start",
               params: { event: { actor: "avi" } },
               headers: @headers,
               as: :json
        end

        assert_response :created
        event = @release.release_events.last
        assert_equal "ship_gate", event.step
        assert_equal "started", event.status
        assert_equal "avi", event.actor
      end

      test "complete requires usage for api-authored events" do
        post "/api/v1/releases/#{@release.slug}/events/ship_gate/complete",
             params: { event: { actor: "avi" } },
             headers: @headers,
             as: :json

        assert_response :unprocessable_entity
        assert_equal "MISSING_EVENT_USAGE", response.parsed_body["error_code"]
      end

      test "complete records usage when supplied" do
        post "/api/v1/releases/#{@release.slug}/events/confirming/complete",
             params: {
               event: {
                 actor: "avi",
                 model: "gpt-5",
                 tokens_in: 1000,
                 tokens_out: 200,
                 cost: "0.0500",
                 idempotency_key: "confirming-complete"
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        event = @release.release_events.last
        assert_equal "ship_gate", event.step, "tracker-stage aliases normalize to canonical event steps"
        assert_equal "completed", event.status
        assert_equal 1200, event.tokens_total
        assert_equal "0.05".to_d, event.cost
      end

      test "unknown release returns a clean 404" do
        post "/api/v1/releases/no-such-release/events/ship_gate/start",
             headers: @headers,
             as: :json

        assert_response :not_found
      end

      # --- stage timeline over the API ------------------------------------------

      test "[integration] posting an event stamps the mapped stage and returns the snapshot" do
        post "/api/v1/releases/#{@release.slug}/events/qa_deploying/start",
             params: { event: { actor: "steffon" } },
             headers: @headers,
             as: :json

        assert_response :created
        assert @release.reload.qa_deploy_started_at.present?
        snapshot = response.parsed_body.dig("data", "release")
        assert_equal @release.slug, snapshot["slug"]
        assert_equal "qa_deploying", snapshot["stage"]
        assert snapshot["stage_stamps"]["qa_deploying"].present?
        assert_nil snapshot["stage_stamps"]["confirming"]
      end

      test "[integration] the Steffon→Avi handoff over the API: Live on QA does not start Confirming" do
        post "/api/v1/releases/#{@release.slug}/events/qa_deploying/complete",
             params: { event: { actor: "steffon", model: "claude-opus-4-8", tokens_in: 10, tokens_out: 5, cost: "0.01" } },
             headers: @headers,
             as: :json
        assert_response :created
        @release.reload
        assert @release.qa_deployed_at.present?, "Steffon's completion is Live on QA"
        assert_nil @release.confirming_started_at, "stage 4 must stay dark until Avi notifies"

        post "/api/v1/releases/#{@release.slug}/events/confirming/start",
             params: { event: { actor: "avi" } },
             headers: @headers,
             as: :json
        assert_response :created
        @release.reload
        assert @release.confirming_started_at.present?, "Avi's start lights stage 4"
        assert_equal "confirming", @release.current_stage
      end

      test "[integration] slug `current` resolves the active release" do
        post "/api/v1/releases/current/events/confirming/start",
             params: { event: { actor: "avi" } },
             headers: @headers,
             as: :json

        assert_response :created
        assert @release.reload.confirming_started_at.present?
      end

      test "[integration] slug `current` with no active release 404s for late stages, never a ghost RC" do
        @release.abandon!

        assert_no_difference -> { Release.count } do
          post "/api/v1/releases/current/events/confirming/start",
               params: { event: { actor: "avi" } },
               headers: @headers,
               as: :json
        end

        assert_response :not_found
      end

      test "[integration] slug `current` may OPEN the next candidate for a review kick-off" do
        @release.abandon!

        assert_difference -> { Release.count }, 1 do
          post "/api/v1/releases/current/events/testing/start",
               params: { event: { actor: "avi" } },
               headers: @headers,
               as: :json
        end

        assert_response :created
        fresh = Release.current
        assert fresh.testing_started_at.present?
        assert_equal "testing", fresh.current_stage
      end
    end
  end
end
