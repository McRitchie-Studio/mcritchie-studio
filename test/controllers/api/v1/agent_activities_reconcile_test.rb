require "test_helper"

module Api
  module V1
    # Integration coverage for the fan-out-token-attribution endpoints:
    #   GET  /api/v1/agent_activities/windows    — the reconciler's window feed
    #   POST /api/v1/agent_activities/reconcile  — stamp the computed per-activity usage
    class AgentActivitiesReconcileTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
        @t0 = Time.utc(2026, 7, 11, 3, 12, 0)
        @a1 = AgentActivity.create!(session_id: "sess-fx", category: "Workflow", reason_slug: "kick off",
                                    agent: nil, seq: 0, opened_at: @t0, closed_at: @t0 + 60)
        @a2 = AgentActivity.create!(session_id: "sess-fx", category: "Verify", reason_slug: "review",
                                    agent: "carl", seq: 1, opened_at: @t0 + 60, closed_at: nil)
      end

      # ---- [integration] windows -----------------------------------------------

      test "[integration] windows returns the session's activity windows chronologically" do
        get windows_api_v1_agent_activities_path, params: { session_id: "sess-fx" }, headers: @headers

        assert_response :ok
        rows = response.parsed_body.fetch("data")
        assert_equal [@a1.id, @a2.id], rows.map { |r| r["id"] }
        assert_equal [nil, "carl"], rows.map { |r| r["agent"] }
        assert_equal "2026-07-11T03:12:00Z", rows.first["opened_at"], "opened_at is ISO8601 UTC for the plain-Ruby reconciler"
        assert_equal "2026-07-11T03:13:00Z", rows.first["closed_at"]
        assert_nil rows.last["closed_at"], "a never-closed activity reports a null close"
      end

      test "[integration] windows for an unknown session is an empty list, not an error" do
        get windows_api_v1_agent_activities_path, params: { session_id: "nope" }, headers: @headers
        assert_response :ok
        assert_empty response.parsed_body.fetch("data")
      end

      # ---- [integration] reconcile ---------------------------------------------

      test "[integration] reconcile stamps per-activity usage and cost, lighting up measured_usage?" do
        refute @a1.measured_usage?

        post reconcile_api_v1_agent_activities_path,
             params: { session_id: "sess-fx", usages: [
               { activity_id: @a1.id, model: "claude-opus-4-8", tokens_in: 4970, tokens_out: 16,
                 cache_read_tokens: 300_000, cost: 0.2354 },
               { activity_id: @a2.id, model: "claude-opus-4-8", tokens_in: 42_618, tokens_out: 13,
                 cache_read_tokens: 700_000, cost: 0.5201 }
             ] }, headers: @headers, as: :json

        assert_response :ok
        assert_equal 2, response.parsed_body.dig("data", "reconciled")

        @a1.reload
        assert @a1.measured_usage?, "a previously-blank activity now measures"
        assert_equal 4970, @a1.tokens_in
        assert_equal 16, @a1.tokens_out
        assert_equal 300_000, @a1.cache_read_tokens
        assert_in_delta 0.2354, @a1.cost.to_f, 0.00001
        assert_equal "claude-opus-4-8", @a1.model
      end

      test "[integration] reconcile never patches an activity outside the given session" do
        other = AgentActivity.create!(session_id: "sess-OTHER", category: "Edit", reason_slug: "x",
                                      seq: 0, opened_at: @t0)

        post reconcile_api_v1_agent_activities_path,
             params: { session_id: "sess-fx", usages: [
               { activity_id: other.id, model: "claude-opus-4-8", tokens_in: 9999, tokens_out: 9999, cost: 1.0 }
             ] }, headers: @headers, as: :json

        # No sess-fx activity matched other.id → 204 no-op, and the cross-session row is untouched.
        assert_response :no_content
        refute other.reload.measured_usage?, "a token can never patch another session's activity"
      end

      test "[integration] reconcile with no matching activities is a 204 no-op" do
        post reconcile_api_v1_agent_activities_path,
             params: { session_id: "sess-fx", usages: [
               { activity_id: 999_999, model: "claude-opus-4-8", tokens_in: 1, tokens_out: 1, cost: 0.01 }
             ] }, headers: @headers, as: :json
        assert_response :no_content
      end

      test "[integration] reconcile drops a zero-spend usage rather than clobbering with nils" do
        @a1.update!(model: "claude-opus-4-8", tokens_in: 100, tokens_out: 5, cost: 0.01)

        post reconcile_api_v1_agent_activities_path,
             params: { session_id: "sess-fx", usages: [
               { activity_id: @a1.id, model: "", tokens_in: 0, tokens_out: 0, cache_read_tokens: 0, cost: 0 }
             ] }, headers: @headers, as: :json

        assert_response :no_content
        assert_equal 100, @a1.reload.tokens_in, "an all-zero usage must not blank an existing measurement"
      end

      test "[integration] windows requires auth" do
        get windows_api_v1_agent_activities_path, params: { session_id: "sess-fx" }
        assert_response :unauthorized
      end
    end
  end
end
