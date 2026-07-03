require "test_helper"

module Api
  module V1
    # [integration] the bearer AGENT grading path for the Alex heartbeat grade-events
    # loop: awaiting_grade lists resolved ungraded spans; grade upserts Alex's grade.
    # The grader is FORCED to alex — the mcr audit stays admin-browser-only.
    class EventGradesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      def resolved_span(session_id:, reason: "resolved span here")
        AtomicEvent.open_event!(session_id: session_id, category: "Verify", reason_slug: reason)
        AtomicEvent.close_event!(session_id: session_id, outcome_slug: "done")
      end

      # ---- awaiting_grade -------------------------------------------------------

      test "[integration] awaiting_grade lists resolved ungraded spans with content" do
        span = resolved_span(session_id: "ctl-aw", reason: "grade this span")

        get api_v1_awaiting_grade_atomic_events_path, headers: @headers

        assert_response :ok
        body = response.parsed_body
        assert_equal 1, body.dig("meta", "count")
        row = body["data"].first
        assert_equal span.id, row["id"]
        assert_equal "grade this span", row["reason"]
        assert_equal "done", row["outcome"]
      end

      test "[integration] awaiting_grade requires auth — 401 without a token" do
        get api_v1_awaiting_grade_atomic_events_path
        assert_response :unauthorized
      end

      # ---- grade ----------------------------------------------------------------

      test "[integration] grade upserts Alex's grade of a span and returns it" do
        span = resolved_span(session_id: "ctl-grade")

        assert_difference -> { ActionGrade.count }, 1 do
          post api_v1_grade_atomic_event_path(span.id),
               params: { disposition: "good", slug: "clean sharp outcome", intent: "bank" },
               headers: @headers, as: :json
        end

        assert_response :created
        data = response.parsed_body["data"]
        assert_equal "alex", data["grader"]
        assert_equal "good", data["disposition"]
        assert_equal "clean sharp outcome", data["slug"]
        assert_equal true, data["banked"]
      end

      test "[integration] grade FORCES the grader to alex — a client-supplied mcr is ignored" do
        span = resolved_span(session_id: "ctl-force")

        post api_v1_grade_atomic_event_path(span.id),
             params: { grader: "mcr", disposition: "good", slug: "cannot forge the audit" },
             headers: @headers, as: :json

        assert_response :created
        assert_equal "alex", response.parsed_body.dig("data", "grader"),
                     "the agent path never writes an mcr audit grade"
        assert_nil ActionGrade.for_event(span).by_grader("mcr").first, "no mcr row is created"
      end

      test "[integration] grade on a missing span is a 404" do
        post api_v1_grade_atomic_event_path(999_999),
             params: { disposition: "good" }, headers: @headers, as: :json

        assert_response :not_found
      end

      test "[integration] a failed grade write is captured with the span as target context" do
        span = resolved_span(session_id: "ctl-errlog")

        ActionGrade.stub(:record_event_grade, ->(**) { raise "write blew up" }) do
          assert_difference -> { ErrorLog.count }, 1 do
            # in test env the unexpected error re-raises; our rescue has already
            # written the target-linked ErrorLog before re-raising.
            assert_raises(RuntimeError) do
              post api_v1_grade_atomic_event_path(span.id),
                   params: { disposition: "good" }, headers: @headers, as: :json
            end
          end
        end

        log = ErrorLog.order(:id).last
        assert_equal span, log.target, "the failed write is linked to its span, not a bare 500"
        assert_equal "span ##{span.id}", log.target_name
      end

      test "[integration] grade requires auth — 401 without a token" do
        span = resolved_span(session_id: "ctl-noauth")

        assert_no_difference -> { ActionGrade.count } do
          post api_v1_grade_atomic_event_path(span.id), params: { disposition: "good" }, as: :json
        end

        assert_response :unauthorized
      end
    end
  end
end
