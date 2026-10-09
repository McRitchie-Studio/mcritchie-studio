require "test_helper"

module Api
  module V1
    class ReleaseEventsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @release = Release.open!
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}"
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

      test "[integration] slug `current` testing/start never opens a candidate — only assembly-start may" do
        @release.abandon!

        # The review wave runs BEFORE any release exists. A testing/start post with
        # no active candidate must be a clean 404, never a ghost RC — the empty
        # `assembling` release that used to surface on /deployments before qa-release.
        assert_no_difference -> { Release.count } do
          post "/api/v1/releases/current/events/testing/start",
               params: { event: { actor: "avi" } },
               headers: @headers,
               as: :json
        end
        assert_response :not_found

        # Assembly-start (the qa-release sweep's kick-off) is the sole API opener.
        assert_difference -> { Release.count }, 1 do
          post "/api/v1/releases/current/events/assembling/start",
               params: { event: { actor: "steffon" } },
               headers: @headers,
               as: :json
        end
        assert_response :created
        fresh = Release.current
        assert fresh.assembling_started_at.present?
        assert_equal "assembling", fresh.current_stage
      end

      # --- ship_authorized: production authority takes an admin session ---------

      def ship_authorized_path(action) = "/api/v1/releases/#{@release.slug}/events/ship_authorized/#{action}"

      def session_headers(session) = { "Authorization" => "Bearer #{session.token}" }

      def timed_request!
        @release.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                               metadata: { "mode" => "timed", "window_ends_at" => 30.minutes.from_now.utc.iso8601 })
      end

      def assert_refused_for_want_of_an_admin_session(holder)
        assert_response :forbidden
        body = response.parsed_body
        assert_equal "SESSION_FORBIDDEN", body["error_code"]
        assert_match(/needs an admin session; #{holder}/, body["error"])
        assert_match(/bin\/agent-activity heartbeat steffon/, body["error"], "the refusal says how to get one")
      end

      test "[unit] the shared token posting ship_authorized completed answers 403 and grants nothing" do
        timed_request!

        assert_no_difference -> { ReleaseEvent.count } do
          post ship_authorized_path("complete"),
               params: { event: { actor: "alex@mcritchie.studio", source: "web", metadata: { granted_via: "web" } } },
               headers: @headers, as: :json
        end

        assert_refused_for_want_of_an_admin_session("the shared token carries no session")
        refute @release.reload.ship_authorization_granted?
        refute @release.ship_authorization_state["granted"], "the read bin/release ship polls"
      end

      test "[unit] an admin session posting ship_authorized completed records the grant" do
        timed_request!
        session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")

        assert_difference -> { ReleaseEvent.where(step: "ship_authorized", status: "completed").count }, 1 do
          post ship_authorized_path("complete"),
               params: { event: { actor: "someone-else", source: "web", metadata: { granted_via: "web" } } },
               headers: session_headers(session), as: :json
        end

        assert_response :created
        assert @release.reload.ship_authorization_granted?
        assert_equal "steffon", @release.ship_authorization_grant.actor, "the actor is the session's soul"
      end

      test "[unit] a studio session posting ship_authorized completed is refused with the way in" do
        timed_request!
        task = Task.create!(title: "Ship Authority Studio Session", stage: "building")
        session = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")

        assert_no_difference -> { ReleaseEvent.count } do
          post ship_authorized_path("complete"), params: { event: { source: "web" } },
               headers: session_headers(session), as: :json
        end

        assert_refused_for_want_of_an_admin_session("pokemon holds a studio session")
        refute @release.reload.ship_authorization_granted?
      end

      test "[unit] the shared token cannot open or fail a ship_authorized request either" do
        %w[start fail].each do |action|
          assert_no_difference -> { ReleaseEvent.count }, action do
            post ship_authorized_path(action), params: { event: { actor: "avi" } }, headers: @headers, as: :json
          end
          assert_refused_for_want_of_an_admin_session("the shared token carries no session")
        end
        assert_nil @release.reload.ship_authorization_request
      end

      test "[unit] the admin gate answers before the release is looked up" do
        post "/api/v1/releases/no-such-release/events/ship_authorized/complete",
             params: { event: { source: "web" } }, headers: @headers, as: :json

        assert_refused_for_want_of_an_admin_session("the shared token carries no session")
      end

      test "[unit] control: the shared token still records every other release step" do
        assert_difference -> { ReleaseEvent.count }, 1 do
          post "/api/v1/releases/#{@release.slug}/events/ship_gate/start",
               params: { event: { actor: "avi" } }, headers: @headers, as: :json
        end
        assert_response :created
      end
    end
  end
end
