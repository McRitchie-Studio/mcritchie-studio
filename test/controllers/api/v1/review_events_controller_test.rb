require "test_helper"

module Api
  module V1
    class ReviewEventsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = Task.create!(title: "review api task", stage: "submitted")
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "[integration] creates an idempotent primary review check-in" do
        payload = {
          review_event: {
            role: "primary",
            moment: "diff",
            status: "info",
            actor: "carl",
            source: "agent",
            message: "Controllers and routes reviewed.",
            idempotency_key: "review-api-task:primary:diff"
          }
        }

        assert_difference -> { @task.task_events.checkpoints.count }, 1 do
          post "/api/v1/tasks/#{@task.slug}/review_events", params: payload, headers: @headers, as: :json
        end
        assert_response :created

        assert_no_difference -> { @task.task_events.checkpoints.count } do
          post "/api/v1/tasks/#{@task.slug}/review_events", params: payload, headers: @headers, as: :json
        end
        assert_response :created

        event = @task.task_events.checkpoints.last
        assert_equal "review_primary_diff", event.to_stage
        assert_equal "primary", event.review_role
        assert_equal "diff", event.review_moment
        assert_equal "Controllers and routes reviewed.", event.review_message
        assert_equal "review-api-task:primary:diff", event.metadata["idempotency_key"]

        body = JSON.parse(response.body)
        assert_equal "primary", body.dig("data", "review_role")
        assert_equal "diff", body.dig("data", "review_moment")
      end

      test "[integration] completed review check-ins require usage" do
        post "/api/v1/tasks/#{@task.slug}/review_events",
             params: { review_event: { role: "light", moment: "completed", actor: "shannon", source: "agent" } },
             headers: @headers,
             as: :json

        assert_response :unprocessable_entity
        assert_equal "MISSING_EVENT_USAGE", JSON.parse(response.body)["error_code"]

        post "/api/v1/tasks/#{@task.slug}/review_events",
             params: {
               review_event: {
                 role: "light",
                 moment: "completed",
                 actor: "shannon",
                 source: "agent",
                 model: "gpt-5",
                 tokens_in: 1200,
                 tokens_out: 400,
                 cost: "0.0800"
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        event = @task.task_events.checkpoints.last
        assert_equal "light", event.review_role
        assert_equal "completed", event.review_status
        assert_equal 1600, event.tokens_total
        assert_equal "0.0800".to_d, event.cost
      end

      test "[integration] rejects unknown review moments" do
        post "/api/v1/tasks/#{@task.slug}/review_events",
             params: { review_event: { role: "primary", moment: "surprise", actor: "carl" } },
             headers: @headers,
             as: :json

        assert_response :unprocessable_entity
        assert_match "review moment must be one of", JSON.parse(response.body)["error"]
      end
    end
  end
end
