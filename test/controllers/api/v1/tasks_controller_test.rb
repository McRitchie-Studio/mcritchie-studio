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
                  acceptance: ["Task card shows the devops metadata", "QA URL opens the QA board"],
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
        assert_equal ["Task card shows the devops metadata", "QA URL opens the QA board"], @task.devops_acceptance
        assert_equal ["bin/rails test test/controllers/api/v1/tasks_controller_test.rb"], @task.devops_checks_run
        assert @task.requires_release_conductor?
      end

      test "create preserves commas inside array acceptance items" do
        post api_v1_tasks_path,
             params: {
               title: "Comma in acceptance",
               devops: {
                 repositories: ["mcritchie-studio"],
                 acceptance: ["Header stays pinned, even while scrolling", "Email still works as expected"]
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        slug = JSON.parse(response.body).dig("data", "slug")
        created = Task.find_by!(slug: slug)
        assert_equal ["Header stays pinned, even while scrolling", "Email still works as expected"], created.devops_acceptance
      end

      test "create with a custom slug sets a readable slug and trickles to worktree_slug + branch" do
        post api_v1_tasks_path,
             params: { slug: "Readable Handle Here", title: "valid four word title", devops: { repositories: ["mcritchie-studio"] } },
             headers: @headers,
             as: :json

        assert_response :created
        created = Task.find_by!(slug: "readable-handle-here")
        assert_equal "readable-handle-here", created.devops_worktree_slug
        assert_equal "feat/readable-handle-here", created.metadata.dig("devops", "branch")
      end

      test "update ignores a slug in the body (slug is create-only)" do
        original = @task.slug
        patch api_v1_task_path(@task.slug),
              params: { slug: "hacked-slug", title: "renamed task title here" },
              headers: @headers,
              as: :json

        assert_response :success
        @task.reload
        assert_equal original, @task.slug, "update must not change the immutable slug"
        assert_equal "renamed task title here", @task.title
      end

      test "create enforces the 3-5 word title (naming discipline)" do
        post api_v1_tasks_path,
             params: { title: "way too many words in this task title now" }, # 9 words
             headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match(/3-5 words/, JSON.parse(response.body)["error"])
      end

      test "create enforces 5-12 word acceptance bullets" do
        post api_v1_tasks_path,
             params: { title: "valid four word title", devops: { acceptance: ["too short"] } },
             headers: @headers, as: :json
        assert_response :unprocessable_entity
      end

      test "create accepts a compliant title and acceptance" do
        post api_v1_tasks_path,
             params: { title: "valid four word title", devops: { acceptance: ["the user can log in fine"] } },
             headers: @headers, as: :json
        assert_response :created
      end

      # A scalar `event` (e.g. ?event=foo) used to raise TypeError in the
      # before_action when it symbol-indexed a String. Guard it: the move still
      # lands and source falls back to the default "api".
      test "a scalar event param does not raise and falls back to source=api" do
        patch api_v1_task_path(@task.slug),
              params: { stage: "building", event: "oops" },
              headers: @headers, as: :json

        assert_response :success
        @task.reload
        event = @task.task_events.chronological.last
        assert_equal "building", event.to_stage
        assert_equal "api", event.source
      end
    end
  end
end
