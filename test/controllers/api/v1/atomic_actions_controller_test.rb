require "test_helper"
# Object#stub — the best-effort/mapping tests force capture to a known return
# value standalone (matches the repo's per-file mock convention).
require "minitest/mock"

module Api
  module V1
    class AtomicActionsControllerTest < ActionDispatch::IntegrationTest
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
          input: "write app/controllers/api/v1/atomic_actions_controller.rb",
          output: "file created",
          outcome: "ok",
          actor: "harness",
          stage: "building",
          occurred_at: "2026-06-30T09:00:00Z",
          duration_ms: 1234
        }
      end

      # ---- [unit] params -> capture mapping ------------------------------------

      test "[unit] maps the request body onto AtomicAction.capture attributes" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AtomicAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AtomicAction.stub(:capture, stub) do
          post api_v1_atomic_actions_path, params: @body, headers: @headers, as: :json
        end

        assert_response :created
        assert_equal "sess-abc", captured[:session_id]
        assert_equal "edit", captured[:kind]
        assert_equal @task.slug, captured[:task_slug]
        assert_equal "rotom", captured[:mascot]
        assert_equal "write app/controllers/api/v1/atomic_actions_controller.rb", captured[:input]
        assert_equal "file created", captured[:output]
        assert_equal "ok", captured[:outcome]
        assert_equal "harness", captured[:actor]
        assert_equal "building", captured[:stage]
        assert_equal "2026-06-30T09:00:00Z", captured[:occurred_at]
        assert_equal 1234, captured[:duration_ms]
      end

      test "[unit] drops blank scalars so capture's own defaults engage" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AtomicAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AtomicAction.stub(:capture, stub) do
          post api_v1_atomic_actions_path,
               params: { session_id: "sess-1", kind: "read", outcome: "", actor: "", occurred_at: "" },
               headers: @headers, as: :json
        end

        assert_response :created
        assert_equal %i[kind session_id], captured.keys.sort,
                     "blank optional fields are stripped before reaching capture"
        assert_not captured.key?(:outcome)
        assert_not captured.key?(:occurred_at)
      end

      test "[unit] does not permit tokens cost or distillation slugs" do
        captured = nil
        stub = lambda do |attrs|
          captured = attrs
          AtomicAction.new(session_id: attrs[:session_id], kind: attrs[:kind])
        end

        AtomicAction.stub(:capture, stub) do
          post api_v1_atomic_actions_path,
               params: @body.merge(tokens_in: 999, cost: "9.99", event_slug: "x", result_slug: "y", seq: 42),
               headers: @headers, as: :json
        end

        assert_response :created
        %i[tokens_in cost event_slug result_slug seq].each do |forbidden|
          assert_not captured.key?(forbidden), "#{forbidden} must not be caller-settable"
        end
      end

      # ---- [integration] persistence -------------------------------------------

      test "[integration] create persists one AtomicAction and returns 201 with it" do
        action = nil
        assert_difference -> { AtomicAction.count }, 1 do
          post api_v1_atomic_actions_path, params: @body, headers: @headers, as: :json
        end

        assert_response :created
        body = response.parsed_body.fetch("data")
        action = AtomicAction.order(:created_at).last
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
        assert_difference -> { AtomicAction.count }, 1 do
          post api_v1_atomic_actions_path,
               params: { session_id: "sess-min", kind: "read" },
               headers: @headers, as: :json
        end

        assert_response :created
        action = AtomicAction.order(:created_at).last
        assert_equal AtomicAction::PENDING, action.outcome
        assert_equal AtomicAction::AGENT, action.actor
        assert action.occurred_at.present?, "occurred_at defaults to capture time"
      end

      # ---- [integration] auth ---------------------------------------------------

      test "[integration] requires auth — 401 without a token" do
        assert_no_difference -> { AtomicAction.count } do
          post api_v1_atomic_actions_path, params: @body, as: :json
        end

        assert_response :unauthorized
      end

      test "[integration] requires auth — 401 with an invalid token" do
        assert_no_difference -> { AtomicAction.count } do
          post api_v1_atomic_actions_path, params: @body,
               headers: { "Authorization" => "Bearer not-a-real-token" }, as: :json
        end

        assert_response :unauthorized
      end

      # ---- [integration] best-effort: a capture miss never 500s -----------------

      test "[integration] a capture miss returns 204 and never 500s the caller" do
        AtomicAction.stub(:capture, nil) do
          assert_no_difference -> { AtomicAction.count } do
            post api_v1_atomic_actions_path, params: @body, headers: @headers, as: :json
          end
        end

        assert_response :no_content
      end
    end
  end
end
