require "test_helper"

# hub-web-memory-stays-under: agent-telemetry bodies (prompts, command output,
# diffs, turn preambles) must never reach the request log's `Parameters:` line.
#
# The log line is printed by ActionController::LogSubscriber from the
# `start_processing.action_controller` payload's :params, so these tests read
# that payload directly AND render a real log through the subscriber.
module Api
  module V1
    class TelemetryLogFilterTest < ActionDispatch::IntegrationTest
      # Long enough to be unmistakable, and nothing a filter could match by accident.
      LONG_PROMPT = ("Investigate the hub web dyno memory curve and report back. " * 80).freeze

      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}"
        }
      end

      test "[unit] agent_actions#create logs no input or output body, top-level or wrapped" do
        params = logged_params_for do
          post api_v1_agent_actions_path,
               params: { session_id: "sess-log", kind: "delegate", task_slug: @task.slug,
                         input: LONG_PROMPT, output: LONG_PROMPT, outcome: "ok",
                         tokens_in: 1200, tokens_out: 80 },
               headers: @headers, as: :json
        end

        assert_equal "[FILTERED]", params["input"]
        assert_equal "[FILTERED]", params["output"]
        assert_equal "[FILTERED]", params.dig("agent_action", "input"),
          "the params-wrapper copy must be masked too"
        refute_includes params.to_s, LONG_PROMPT.first(60)
        # Non-body telemetry stays readable for debugging.
        assert_equal "sess-log", params["session_id"]
        assert_equal "delegate", params["kind"]
      end

      test "[unit] turn_open logs no preamble or prompt body" do
        params = logged_params_for do
          post turn_open_api_v1_agent_activities_path,
               params: { session_id: "sess-log", turn_uuid: "t-1", preamble: LONG_PROMPT,
                         prompt: LONG_PROMPT },
               headers: @headers, as: :json
        end

        assert_equal "[FILTERED]", params["preamble"]
        assert_equal "[FILTERED]", params["prompt"]
        refute_includes params.to_s, LONG_PROMPT.first(60)
        assert_equal "t-1", params["turn_uuid"]
      end

      test "[integration] the rendered request log never carries the prompt, and capture still stores it" do
        io = StringIO.new
        logger = ActiveSupport::Logger.new(io)
        original = ActionController::Base.logger
        ActionController::Base.logger = logger
        begin
          post api_v1_agent_actions_path,
               params: { session_id: "sess-log-int", kind: "delegate", task_slug: @task.slug,
                         input: LONG_PROMPT, outcome: "ok" },
               headers: @headers, as: :json
        ensure
          ActionController::Base.logger = original
        end

        assert_response :created
        log = io.string
        assert_match(/Parameters: .*"input" ?=> ?"\[FILTERED\]"/, log)
        refute_includes log, LONG_PROMPT.first(60)
        # Only the log changes: the action still received and stored the body.
        stored = AgentAction.where(session_id: "sess-log-int").last
        assert stored, "capture must still persist the action"
        assert_includes stored.input.to_s, LONG_PROMPT.first(60)
      end

      test "[unit] the body keys are NOT in the global filter list, so other params and models keep them" do
        global = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

        assert_equal({ "input" => "x", "output" => "y", "preamble" => "z" },
          global.filter("input" => "x", "output" => "y", "preamble" => "z"))
      end

      private

      def logged_params_for
        payloads = []
        callback = ->(*, payload) { payloads << payload }
        ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") { yield }
        assert_equal 1, payloads.size, "expected exactly one processed request"
        payloads.first.fetch(:params)
      end
    end
  end
end
