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

      test "[integration] create permits supervisor and stamps structured supervisor attribution" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-supervisor", category: "Verify", reason: "review",
                       agent: "carl", supervisor: "avi" },
             headers: @headers, as: :json

        assert_response :created
        activity = AgentActivity.for_session("sess-supervisor").order(:seq).last
        assert_equal "carl", activity.agent
        assert_equal "avi", activity.supervisor_agent
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

      test "[integration] create with prior usage stamps the auto-closed prior span" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-boundary-usage", category: "Explore", reason: "find issue with api" },
             headers: @headers, as: :json
        first = AgentActivity.order(:created_at).last

        post api_v1_agent_activities_path,
             params: { session_id: "sess-boundary-usage", category: "Edit", reason: "add the guard",
                       prior_outcome: "located the bug", prior_model: "claude-opus-4-8",
                       prior_tokens_in: 9400, prior_tokens_out: 360,
                       prior_cache_read_tokens: 42_000, prior_cost: "0.2579" },
             headers: @headers, as: :json

        assert_response :created
        first.reload
        assert first.measured_usage?
        assert_equal "claude-opus-4-8", first.model
        assert_equal 9400, first.tokens_in
        assert_equal 360, first.tokens_out
        assert_equal 42_000, first.cache_read_tokens
        assert_equal BigDecimal("0.2579"), first.cost
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

      test "[integration] close permits measured usage from the owning session" do
        post api_v1_agent_activities_path,
             params: { session_id: "sess-close-usage", category: "Verify", reason: "review diff", agent: "carl" },
             headers: @headers, as: :json

        post close_api_v1_agent_activities_path,
             params: { session_id: "sess-close-usage", agent: "carl", outcome: "approved",
                       model: "claude-opus-4-8", tokens_in: 6200, tokens_out: 383,
                       cache_read_tokens: 304_000, cost: "0.0705" },
             headers: @headers, as: :json

        assert_response :ok
        event = AgentActivity.for_session("sess-close-usage").order(:seq).last
        assert event.measured_usage?
        assert_equal "claude-opus-4-8", event.model
        assert_equal 6200, event.tokens_in
        assert_equal 383, event.tokens_out
        assert_equal 304_000, event.cache_read_tokens
        assert_equal BigDecimal("0.0705"), event.cost
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

      # ---- [integration] turn_open — the derived, turn-keyed lifecycle ---------

      test "[integration] turn_open opens a GENESIS span for the session's first turn" do
        post turn_open_api_v1_agent_activities_path,
             params: { session_id: "to-genesis", turn_uuid: "t-1", mascot: "charmander",
                       preamble: "Let me orient on the schema." },
             headers: @headers, as: :json

        assert_response :ok
        span = AgentActivity.for_session("to-genesis").sole
        assert_equal "A wild Charmander appeared", span.reason_slug
        assert_equal "t-1", span.turn_uuid
        assert span.open?
      end

      test "[integration] turn_open is IDEMPOTENT — a turn's parallel calls share ONE span" do
        2.times do
          post turn_open_api_v1_agent_activities_path,
               params: { session_id: "to-idem", turn_uuid: "t-1", mascot: "pikachu",
                         preamble: "Reading files." },
               headers: @headers, as: :json
          assert_response :ok
        end

        assert_equal 1, AgentActivity.for_session("to-idem").count, "one span for a shared turn_uuid"
      end

      test "[integration] turn_open seals the prior span and splits the preamble at a boundary" do
        post turn_open_api_v1_agent_activities_path,
             params: { session_id: "to-bnd", turn_uuid: "t-1", mascot: "bulbasaur",
                       preamble: "Orienting." },
             headers: @headers, as: :json
        post turn_open_api_v1_agent_activities_path,
             params: { session_id: "to-bnd", turn_uuid: "t-2",
                       preamble: "Found the guard. Now let me add a test." },
             headers: @headers, as: :json

        assert_response :ok
        prior   = AgentActivity.for_session("to-bnd").order(:seq).first
        current = AgentActivity.for_session("to-bnd").open.sole
        assert prior.closed?
        assert_equal "Found the guard.", prior.outcome_slug, "the lead sentence seals the prior span"
        assert_equal "Now let me add a test.", current.reason_slug, "the rest is the new reason"
        assert_equal "t-2", current.turn_uuid
      end

      test "[integration] turn_open is a 204 no-op on a blank turn_uuid" do
        post turn_open_api_v1_agent_activities_path,
             params: { session_id: "to-blank", turn_uuid: "" },
             headers: @headers, as: :json

        assert_response :no_content
        assert_equal 0, AgentActivity.for_session("to-blank").count
      end

      test "[integration] turn_open nests a subagent turn (other transcript) under the parent" do
        post turn_open_api_v1_agent_activities_path,
             params: { session_id: "to-nest", turn_uuid: "p-1", mascot: "eevee",
                       preamble: "Delegating the search.", transcript_path: "/main.jsonl" },
             headers: @headers, as: :json
        parent = AgentActivity.for_session("to-nest").order(:seq).first

        post turn_open_api_v1_agent_activities_path,
             params: { session_id: "to-nest", turn_uuid: "s-1",
                       preamble: "Subagent reads files.", transcript_path: "/sub.jsonl" },
             headers: @headers, as: :json
        sub = AgentActivity.for_session("to-nest").order(:seq).last

        assert_response :ok
        assert parent.reload.open?, "the parent Delegate span stays open while the subagent runs"
        assert_equal parent.id, sub.parent_span_id
      end
    end
  end
end
