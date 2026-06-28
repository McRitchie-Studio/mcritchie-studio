require "test_helper"

module Api
  module V1
    class TaskEventsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "start records a lifecycle intent for the next task stage" do
        assert_difference -> { @task.task_events.count }, 1 do
          post "/api/v1/tasks/#{@task.slug}/events/building/start",
               params: { event: { actor: "alex" } },
               headers: @headers,
               as: :json
        end

        assert_response :created
        event = @task.task_events.last
        assert event.intent?
        assert_equal "building", event.to_stage
        assert_equal "alex", event.actor
      end

      test "complete moves a task stage and requires usage" do
        post "/api/v1/tasks/#{@task.slug}/events/building/complete",
             params: { event: { actor: "alex" } },
             headers: @headers,
             as: :json

        assert_response :unprocessable_entity

        post "/api/v1/tasks/#{@task.slug}/events/building/complete",
             params: {
               event: {
                 actor: "alex",
                 model: "gpt-5",
                 tokens_in: 4000,
                 tokens_out: 800,
                 cost: "0.1200"
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        @task.reload
        assert_equal "building", @task.stage
        event = @task.task_events.transitions.last
        assert_equal "building", event.to_stage
        assert_equal 4800, event.tokens_total
      end

      test "heavy review completion records a checkpoint without moving stage" do
        @task.update!(stage: "submitted")

        post "/api/v1/tasks/#{@task.slug}/events/heavy_review/complete",
             params: {
               event: {
                 actor: "carl",
                 model: "gpt-5",
                 tokens_in: 7000,
                 tokens_out: 900,
                 cost: "0.2200"
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        @task.reload
        assert_equal "submitted", @task.stage
        event = @task.task_events.last
        assert event.checkpoint?
        assert_equal "heavy_review", event.to_stage
        assert_equal "completed", event.metadata["status"]
        assert_equal "reviewed", event.metadata["stage"]
      end

      test "fail records the named checkpoint and blocks the task" do
        @task.update!(stage: "submitted")

        post "/api/v1/tasks/#{@task.slug}/events/light_review/fail",
             params: {
               kind: "rework",
               event: {
                 actor: "shannon",
                 model: "gpt-5",
                 tokens_in: 1000,
                 tokens_out: 300,
                 cost: "0.0400"
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        @task.reload
        assert_equal "blocked", @task.stage
        assert_equal "rework", @task.block_kind
        checkpoint = @task.task_events.checkpoints.last
        assert_equal "light_review", checkpoint.to_stage
        assert_equal "failed", checkpoint.metadata["status"]
        blocked = @task.task_events.transitions.last
        assert_equal "blocked", blocked.to_stage
        assert_equal 1300, blocked.tokens_total
      end
    end
  end
end
