require "test_helper"

module Api
  module V1
    # End-to-end cover for the 2026-09-17 incident, at the tier the operator
    # actually hit it: `bin/task move <slug> archived` -> PATCH /api/v1/tasks/:slug
    # -> 422 with a message that named no column.
    class TaskTokenOverflowTest < ActionDispatch::IntegrationTest
      ABOVE_INT4 = 2_231_911_675  # the exact value from the incident
      ABOVE_INT8 = (1 << 63) + 500
      INT8_MAX   = (1 << 63) - 1

      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      test "a stage move carrying a cumulative cache_read above int4 max succeeds" do
        patch "/api/v1/tasks/#{@task.slug}",
              params: {
                stage: "building",
                event: {
                  actor: "carl", model: "claude-opus-5",
                  tokens_in: 120_000, tokens_out: 8_000,
                  cache_creation_tokens: 4_000_000,
                  cache_read_tokens: ABOVE_INT4
                }
              },
              headers: @headers, as: :json

        assert_response :success
        assert_equal "building", @task.reload.stage

        event = @task.task_events.transitions.chronological.last
        assert_equal ABOVE_INT4, event.cache_read_tokens
      end

      test "an out-of-range value the API cannot store names the column in the 422" do
        # seconds_in_from is still a 4-byte column after the bigint migration, so
        # this exercises the real naming path rather than a contrived one.
        @task.task_events.create!(to_stage: "designed", occurred_at: 1.hour.ago)

        error = assert_raises(IntegerColumnRange::OutOfRangeColumnError) do
          @task.task_events.create!(
            to_stage: "building", occurred_at: Time.current, seconds_in_from: ABOVE_INT4
          )
        end

        # What the operator would now read instead of the bare byte-width message.
        assert_includes error.message, "task_events.seconds_in_from"
        assert_not_includes error.message.split("(").first, "ActiveModel::Type::Integer"
      end

      test "the 422 body carries a machine-readable overflow code" do
        # Drive the controller's rescue seam directly: a range error rendered
        # through render_exception must be distinguishable from a plain refusal.
        controller = Api::V1::TasksController.new
        error = IntegerColumnRange::OutOfRangeColumnError.new(
          record: TaskEvent.new, attribute: "seconds_in_from", value: ABOVE_INT4, byte_limit: 4
        )

        assert_equal "VALUE_OUT_OF_RANGE", controller.send(:error_code_for, error)
        assert_equal "VALUE_OUT_OF_RANGE", controller.send(:error_code_for, ActiveModel::RangeError.new("raw"))
        assert_nil controller.send(:error_code_for, RuntimeError.new("something else"))
      end

      test "a telemetry value beyond even bigint clamps and the move still lands" do
        patch "/api/v1/tasks/#{@task.slug}",
              params: {
                stage: "building",
                event: { actor: "carl", model: "claude-opus-5", cache_read_tokens: ABOVE_INT8 }
              },
              headers: @headers, as: :json

        assert_response :success
        assert_equal "building", @task.reload.stage
        assert_equal INT8_MAX, @task.task_events.transitions.chronological.last.cache_read_tokens
      end
    end
  end
end
