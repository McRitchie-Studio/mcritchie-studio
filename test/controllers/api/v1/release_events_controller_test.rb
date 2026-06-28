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
    end
  end
end
