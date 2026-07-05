require "test_helper"
# Object#stub — the best-effort/mapping tests force capture to a known return
# value standalone (matches the repo's per-file mock convention).
require "minitest/mock"

module Api
  module V1
    class AgentActionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
        @body = {
          session_id: "sess-abc",
          kind: "edit",
          task_slug: @task.slug,
          mascot: "rotom",
          input: "write app/controllers/api/v1/agent_actions_controller.rb",
          output: "file created",
          outcome: "ok",
          actor: "harness",
          stage: "building",
          occurred_at: "2026-06-30T09:00:00Z",
          duration_ms: 1234
        }
      end

      # ---- [unit] params -> capture mapping ------------------------------------

      test "[unit] maps the request body onto AgentAction.capture attributes" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AgentAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AgentAction.stub(:capture, stub) do
          post api_v1_agent_actions_path, params: @body, headers: @headers, as: :json
        end

        assert_response :created
        assert_equal "sess-abc", captured[:session_id]
        assert_equal "edit", captured[:kind]
        assert_equal @task.slug, captured[:task_slug]
        assert_equal "rotom", captured[:mascot]
        assert_equal "write app/controllers/api/v1/agent_actions_controller.rb", captured[:input]
        assert_equal "file created", captured[:output]
        assert_equal "ok", captured[:outcome]
        assert_equal "harness", captured[:actor]
        assert_equal "building", captured[:stage]
        assert_equal "2026-06-30T09:00:00Z", captured[:occurred_at]
        assert_equal 1234, captured[:duration_ms]
      end

      test "[integration] create persists summary + key_method (lang inferred when absent)" do
        post api_v1_agent_actions_path,
             params: @body.merge(kind: "bash",
                                 summary: "list board tasks to find slugs",
                                 key_method: "bin/task list | head -60"),
             headers: @headers, as: :json

        assert_response :created
        action = AgentAction.order(:id).last
        assert_equal "list board tasks to find slugs", action.summary
        assert_equal "bin/task list | head -60", action.key_method
        assert_equal "bash", action.key_method_lang, "blank lang falls to the concern's inference"
      end

      test "[unit] drops blank scalars so capture's own defaults engage" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AgentAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AgentAction.stub(:capture, stub) do
          post api_v1_agent_actions_path,
               params: { session_id: "sess-1", kind: "read", outcome: "", actor: "", occurred_at: "" },
               headers: @headers, as: :json
        end

        assert_response :created
        assert_equal %i[kind session_id], captured.keys.sort,
                     "blank optional fields are stripped before reaching capture"
        assert_not captured.key?(:outcome)
        assert_not captured.key?(:occurred_at)
      end

      test "[unit] permits model so the hook can stamp the session model" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AgentAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AgentAction.stub(:capture, stub) do
          post api_v1_agent_actions_path,
               params: @body.merge(model: "claude-opus-4-8"), headers: @headers, as: :json
        end

        assert_response :created
        assert_equal "claude-opus-4-8", captured[:model], "model reaches capture (kills the \"—\")"
      end

      test "[integration] a captured action persists its stamped model" do
        post api_v1_agent_actions_path,
             params: @body.merge(model: "claude-opus-4-8"), headers: @headers, as: :json

        assert_response :created
        assert_equal "claude-opus-4-8", AgentAction.order(:created_at).last.model
      end

      test "[unit] permits usage fields (tokens + source turn) as integers" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AgentAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AgentAction.stub(:capture, stub) do
          post api_v1_agent_actions_path,
               params: @body.merge(tokens_in: "4000", tokens_out: "250",
                                   cache_read_tokens: "304000", source_turn_uuid: "turn-9"),
               headers: @headers, as: :json
        end

        assert_response :created
        assert_equal 4000, captured[:tokens_in], "tokens are coerced to integers"
        assert_equal 250, captured[:tokens_out]
        assert_equal 304_000, captured[:cache_read_tokens], "cache_read is permitted and coerced to an integer"
        assert_equal "turn-9", captured[:source_turn_uuid]
      end

      test "[unit] still does not permit cost or distillation slugs (cost is DERIVED)" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AgentAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AgentAction.stub(:capture, stub) do
          post api_v1_agent_actions_path,
               params: @body.merge(cost: "9.99", event_slug: "x", result_slug: "y", seq: 42),
               headers: @headers, as: :json
        end

        assert_response :created
        %i[cost event_slug result_slug seq].each do |forbidden|
          assert_not captured.key?(forbidden), "#{forbidden} must not be caller-settable"
        end
      end

      test "[integration] a captured action derives cost from the stamped model + tokens" do
        post api_v1_agent_actions_path,
             params: @body.merge(model: "claude-opus-4-8", tokens_in: 1_000_000, tokens_out: 200_000),
             headers: @headers, as: :json

        assert_response :created
        action = AgentAction.order(:created_at).last
        assert_equal 1_000_000, action.tokens_in
        assert_equal "10.0".to_d, action.cost, "cost is priced server-side from model + tokens"
      end

      test "[integration] cache_read is stored apart and priced at the cache tier, not lumped" do
        post api_v1_agent_actions_path,
             params: @body.merge(model: "claude-opus-4-8", tokens_in: 5_000, tokens_out: 250,
                                 cache_read_tokens: 304_000),
             headers: @headers, as: :json

        assert_response :created
        action = AgentAction.order(:created_at).last
        assert_equal 5_000, action.tokens_in, "the fresh tokens are what the caller sent"
        assert_equal 304_000, action.cache_read_tokens
        assert_equal 5_250, action.tokens_total, "the display total excludes cache_read"
        assert_operator action.cost, :<, "0.25".to_d, "cache_read priced at 0.1x keeps a long turn in cents"
      end

      # ---- [integration] persistence -------------------------------------------

      test "[integration] create persists one AgentAction and returns 201 with it" do
        action = nil
        assert_difference -> { AgentAction.count }, 1 do
          post api_v1_agent_actions_path, params: @body, headers: @headers, as: :json
        end

        assert_response :created
        body = response.parsed_body.fetch("data")
        action = AgentAction.order(:created_at).last
        assert_equal "sess-abc", action.session_id
        assert_equal "edit", action.kind
        assert_equal @task.slug, action.task_slug
        assert_equal "ok", action.outcome
        assert_equal "harness", action.actor
        assert_equal "building", action.stage
        assert_equal 1234, action.duration_ms
        assert_equal 0, action.seq, "first action of a fresh session is position 0"
        assert_equal action.id, body["id"]
        assert_equal "edit", body["kind"]
      end

      test "[integration] minimal body (just session_id + kind) captures with defaults" do
        assert_difference -> { AgentAction.count }, 1 do
          post api_v1_agent_actions_path,
               params: { session_id: "sess-min", kind: "read" },
               headers: @headers, as: :json
        end

        assert_response :created
        action = AgentAction.order(:created_at).last
        assert_equal AgentAction::PENDING, action.outcome
        assert_equal AgentAction::AGENT, action.actor
        assert action.occurred_at.present?, "occurred_at defaults to capture time"
      end

      # ---- [integration] auth ---------------------------------------------------

      test "[integration] requires auth — 401 without a token" do
        assert_no_difference -> { AgentAction.count } do
          post api_v1_agent_actions_path, params: @body, as: :json
        end

        assert_response :unauthorized
      end

      test "[integration] requires auth — 401 with an invalid token" do
        assert_no_difference -> { AgentAction.count } do
          post api_v1_agent_actions_path, params: @body,
               headers: { "Authorization" => "Bearer not-a-real-token" }, as: :json
        end

        assert_response :unauthorized
      end

      # ---- [integration] best-effort: a capture miss never 500s -----------------

      test "[integration] a capture miss returns 204 and never 500s the caller" do
        AgentAction.stub(:capture, nil) do
          assert_no_difference -> { AgentAction.count } do
            post api_v1_agent_actions_path, params: @body, headers: @headers, as: :json
          end
        end

        assert_response :no_content
      end
    end
  end
end
