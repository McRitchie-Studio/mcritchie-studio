require "test_helper"

module Api
  module V1
    class TasksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "update stores devops metadata" do
        patch api_v1_task_path(@task.slug),
              params: {
                title: @task.title,
                devops: {
                  kind: "bug",
                  worktree_slug: "task-board-contract",
                  repositories: "mcritchie-studio",
                  local_url: "http://localhost:3004/tasks",
                  qa_url: "https://qa.mcritchie.studio/tasks",
                  release_train: "2026-06-17-studio",
                  requires_release_conductor: "true",
                  acceptance: ["Task card shows metadata", "QA URL opens"],
                  test_plan: "bin/rails test",
                  checks_run: ["bin/rails test test/controllers/api/v1/tasks_controller_test.rb"]
                }
              },
              headers: @headers,
              as: :json

        assert_response :success
        @task.reload
        assert_equal "bug", @task.devops_kind
        assert_equal "task-board-contract", @task.devops_worktree_slug
        assert_equal ["mcritchie-studio"], @task.devops_repositories
        assert_equal "http://localhost:3004/tasks", @task.devops_url(:local)
        assert_equal ["Task card shows metadata", "QA URL opens"], @task.devops_acceptance
        assert_equal ["bin/rails test test/controllers/api/v1/tasks_controller_test.rb"], @task.devops_checks_run
        assert @task.requires_release_conductor?
      end

      test "create preserves commas inside array acceptance items" do
        post api_v1_tasks_path,
             params: {
               title: "Comma in acceptance",
               devops: {
                 repositories: ["mcritchie-studio"],
                 acceptance: ["Header stays pinned, even while scrolling", "Email still works"]
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        slug = JSON.parse(response.body).dig("data", "slug")
        created = Task.find_by!(slug: slug)
        assert_equal ["Header stays pinned, even while scrolling", "Email still works"], created.devops_acceptance
      end
    end
  end
end
