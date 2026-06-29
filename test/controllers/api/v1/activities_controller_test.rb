require "test_helper"

module Api
  module V1
    class ActivitiesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "create records task-linked QA feedback" do
        assert_difference "Activity.count", 1 do
          post api_v1_activities_path,
               params: {
                 task_slug: @task.slug,
                 agent_slug: "alex",
                 activity_type: "qa_feedback",
                 description: "QA blocked until CI is green.",
                 metadata: { source: "api" }
               },
               headers: @headers,
               as: :json
        end

        assert_response :created
        activity = Activity.order(:created_at).last
        assert_equal @task.slug, activity.task_slug
        assert_equal "qa_feedback", activity.activity_type
      end

      test "[integration] create records task-linked clarification" do
        assert_difference "Activity.count", 1 do
          post api_v1_activities_path,
               params: {
                 task_slug: @task.slug,
                 agent_slug: "avi",
                 activity_type: "clarification",
                 description: "Can you confirm if this should wait for CI?",
                 metadata: { source: "api" }
               },
               headers: @headers,
               as: :json
        end

        assert_response :created
        activity = Activity.order(:created_at).last
        assert_equal @task.slug, activity.task_slug
        assert_equal "clarification", activity.activity_type
        assert activity.clarification?
        assert_not activity.blocking_feedback?
      end

      test "index filters activities by task slug" do
        matching = Activity.create!(
          task_slug: @task.slug,
          activity_type: "handoff",
          description: "Ready for Avi review."
        )
        Activity.create!(
          task_slug: tasks(:queued_task).slug,
          activity_type: "handoff",
          description: "Other task."
        )

        get api_v1_activities_path(task_slug: @task.slug), headers: @headers, as: :json

        assert_response :success
        body = response.parsed_body
        descriptions = body.fetch("data").map { |row| row.fetch("description") }
        assert_includes descriptions, matching.description
        assert_not_includes descriptions, "Other task."
      end
    end
  end
end
