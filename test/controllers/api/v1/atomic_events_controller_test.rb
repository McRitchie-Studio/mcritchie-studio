require "test_helper"

module Api
  module V1
    class AgentActivitysControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      # ---- [integration] open a span -------------------------------------------

      test "[integration] create opens a span and returns 201 with it" do
        assert_difference -> { AgentActivity.count }, 1 do
          post api_v1_agent_activities_path,
               params: { session_id: "sess-open", category: "Explore",
                         reason: "find issue with api", task_slug: @task.slug,
                         mascot: "rotom", stage: "building" },
               headers: @headers, as: :json
        end

        assert_response :created
        body = response.parsed_body.fetch("data")
        event = AgentActivity.order(:created_at).last
        assert_equal "sess-open", event.session_id
        assert_equal "Explore", event.category
        assert_equal "find issue with api", event.reason_slug
        assert_equal @task.slug, event.task_slug
        assert_equal "rotom", event.mascot
        assert_equal "building", event.stage
        assert event.open?
        assert_equal 0, event.seq, "the first span of a fresh session is position 0"
        assert_equal event.id, body["id"]
      end

      test "[integration] opening a new span auto-closes the prior open one" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-chain", category: "Explore", reason: "look" },
             headers: @headers, as: :json
        first = AgentActivity.order(:created_at).last

        post api_v1_agent_activities_path,
             params: { session_id: "sess-chain", category: "Edit", reason: "change" },
             headers: @headers, as: :json

        assert_response :created
        assert first.reload.closed?, "the prior open span is auto-closed on the server"
        assert_equal 1, AgentActivity.for_session("sess-chain").open.count
      end

      test "[integration] an unknown category is a 422 not a 500" do
        assert_no_difference -> { AgentActivity.count } do
          post api_v1_agent_activities_path,
               params: { session_id: "sess-bad", category: "Vibe", reason: "x" },
               headers: @headers, as: :json
        end

        assert_response :unprocessable_entity
        assert_equal "VALIDATION_FAILED", response.parsed_body["error_code"]
      end

      # ---- [integration] agent attribution -------------------------------------

      test "[integration] create permits agent and stamps the acting soul" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-agent", category: "Edit", reason: "add guard", agent: "carl" },
             headers: @headers, as: :json

        assert_response :created
        assert_equal "carl", AgentActivity.for_session("sess-agent").order(:seq).last.agent
      end

      test "[integration] create coerces an unknown agent to nil and still returns 201" do
        assert_difference -> { AgentActivity.count }, 1 do
          post api_v1_agent_activities_path,
               params: { session_id: "sess-agent-bad", category: "Edit", reason: "add guard", agent: "team-rocket" },
               headers: @headers, as: :json
        end

        assert_response :created
        assert_nil AgentActivity.for_session("sess-agent-bad").order(:seq).last.agent,
                   "an unknown soul is non-fatally coerced to nil, not a 422"
      end

      # ---- [integration] BOUNDARY transition: create carries prior_outcome -----

      test "[integration] create with prior_outcome closes the prior span WITH that outcome" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-boundary", category: "Explore", reason: "find issue with api" },
             headers: @headers, as: :json
        first = AgentActivity.order(:created_at).last

        # One call crosses the boundary: closes the prior WITH an outcome AND opens next.
        assert_difference -> { AgentActivity.count }, 1 do
          post api_v1_agent_activities_path,
               params: { session_id: "sess-boundary", category: "Edit", reason: "add the guard",
                         prior_outcome: "located the nil-guard bug" },
               headers: @headers, as: :json
        end

        assert_response :created
        assert first.reload.closed?, "the prior span is closed at the boundary"
        assert_equal "located the nil-guard bug", first.outcome_slug, "stamped with the crossover outcome"
        assert_equal 1, AgentActivity.for_session("sess-boundary").open.count
        opened = AgentActivity.for_session("sess-boundary").order(:seq).last
        assert_equal "add the guard", opened.reason_slug
        assert opened.open?
      end

      # ---- [integration] session-end teardown: close_all ----------------------

      test "[integration] close_all closes the open span and returns the count" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-end", category: "Edit", reason: "mid-edit" },
             headers: @headers, as: :json

        post close_all_api_v1_agent_activities_path,
             params: { session_id: "sess-end", outcome: "session ended" },
             headers: @headers, as: :json

        assert_response :ok
        assert_equal 1, response.parsed_body.dig("data", "closed")
        span = AgentActivity.for_session("sess-end").order(:seq).last
        assert span.closed?
        assert_equal "session ended", span.outcome_slug
        assert_equal 0, AgentActivity.for_session("sess-end").open.count
      end

      test "[integration] close_all with nothing open is a 204 no-op" do
        post close_all_api_v1_agent_activities_path,
             params: { session_id: "sess-end-none", outcome: "session ended" },
             headers: @headers, as: :json

        assert_response :no_content
      end

      test "[integration] close_all requires auth — 401 without a token" do
        post close_all_api_v1_agent_activities_path, params: { session_id: "sess-x" }, as: :json

        assert_response :unauthorized
      end

      # ---- [integration] close a span ------------------------------------------

      test "[integration] close stamps the outcome and closes the open span" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-close", category: "Verify", reason: "run tests" },
             headers: @headers, as: :json

        post close_api_v1_agent_activities_path,
             params: { session_id: "sess-close", outcome: "green suite" },
             headers: @headers, as: :json

        assert_response :ok
        event = AgentActivity.for_session("sess-close").order(:seq).last
        assert event.closed?
        assert_equal "green suite", event.outcome_slug
      end

      test "[integration] close stamps the span's key method with an inferred lang" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-km", category: "Edit", reason: "add the guard" },
             headers: @headers, as: :json

        post close_api_v1_agent_activities_path,
             params: { session_id: "sess-km", outcome: "guard added",
                       key_method: "User.find_by(email: ...)" },
             headers: @headers, as: :json

        assert_response :ok
        event = AgentActivity.for_session("sess-km").order(:seq).last
        assert_equal "User.find_by(email: ...)", event.key_method
        assert_equal "ruby", event.key_method_lang
      end

      test "[integration] create with prior_key_method stamps the auto-closed prior span" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-km2", category: "Explore", reason: "orient" },
             headers: @headers, as: :json

        post api_v1_agent_activities_path,
             params: { session_id: "sess-km2", category: "Edit", reason: "make the change",
                       prior_outcome: "seam found",
                       prior_key_method: "grep -rn AgentActivity app/models", prior_key_method_lang: "bash" },
             headers: @headers, as: :json

        assert_response :created
        prior = AgentActivity.for_session("sess-km2").order(:seq).first
        assert_equal "grep -rn AgentActivity app/models", prior.key_method
        assert_equal "bash", prior.key_method_lang
        assert_nil AgentActivity.for_session("sess-km2").order(:seq).last.key_method
      end

      test "[integration] closing with no open span is a 204 no-op" do
        post close_api_v1_agent_activities_path,
             params: { session_id: "sess-none", outcome: "nothing to close" },
             headers: @headers, as: :json

        assert_response :no_content
      end

      test "[integration] close with an agent closes only that soul's lane" do
        # two souls narrate concurrently in one session (the reviewer fan-out)
        post api_v1_agent_activities_path,
             params: { session_id: "sess-lanes", category: "Verify", reason: "backend", agent: "carl" },
             headers: @headers, as: :json
        post api_v1_agent_activities_path,
             params: { session_id: "sess-lanes", category: "Verify", reason: "ui", agent: "shannon" },
             headers: @headers, as: :json

        post close_api_v1_agent_activities_path,
             params: { session_id: "sess-lanes", agent: "carl", outcome: "approve: clean" },
             headers: @headers, as: :json

        assert_response :ok
        assert_equal "approve: clean", response.parsed_body.dig("data", "outcome_slug")
        carl    = AgentActivity.for_session("sess-lanes").where(agent: "carl").order(:seq).last
        shannon = AgentActivity.for_session("sess-lanes").where(agent: "shannon").order(:seq).last
        assert carl.closed?, "carl's lane closed"
        assert shannon.open?, "shannon's lane is untouched by carl's close"
      end

      # ---- [integration] auth ---------------------------------------------------

      test "[integration] create requires auth — 401 without a token" do
        assert_no_difference -> { AgentActivity.count } do
          post api_v1_agent_activities_path,
               params: { session_id: "sess-x", category: "Explore", reason: "x" }, as: :json
        end

        assert_response :unauthorized
      end

      test "[integration] close requires auth — 401 without a token" do
        post close_api_v1_agent_activities_path, params: { session_id: "sess-x" }, as: :json

        assert_response :unauthorized
      end

      # ---- [integration] the full narration flow -------------------------------

      test "[integration] open span -> POST action attributes -> close with outcome" do
        session = "flow-sess"

        # 1. The agent OPENs a span.
        post api_v1_agent_activities_path,
             params: { session_id: session, category: "Explore", reason: "find issue with api" },
             headers: @headers, as: :json
        assert_response :created
        event = AgentActivity.for_session(session).order(:seq).last

        # 2. A raw tool-call POSTs to the actions sink — it attributes server-side
        #    to the open span (the hook never sends agent_activity_id).
        post api_v1_agent_actions_path,
             params: { session_id: session, kind: "read", input: "grep capture" },
             headers: @headers, as: :json
        assert_response :created
        action = AgentAction.for_session(session).order(:seq).last
        assert_equal event.id, action.agent_activity_id, "the action rolled up under the open span"

        # 3. The agent CLOSEs the span with an outcome.
        post close_api_v1_agent_activities_path,
             params: { session_id: session, outcome: "located the nil-guard bug" },
             headers: @headers, as: :json
        assert_response :ok
        assert_equal "located the nil-guard bug", event.reload.outcome_slug
        assert event.closed?
      end

      test "[integration] an action with NO open span attributes to a null span" do
        session = "no-open-flow"

        post api_v1_agent_actions_path,
             params: { session_id: session, kind: "read" },
             headers: @headers, as: :json

        assert_response :created
        action = AgentAction.for_session(session).order(:seq).last
        assert_nil action.agent_activity_id, "no open span → null attribution"
      end
    end
  end
end
