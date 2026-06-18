require "test_helper"
require "minitest/mock"

module Api
  module V1
    class ReleaseNotesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "dry run renders canonical release notes without sending to Discord" do
        task = tasks(:done_task)
        task.update!(
          title: "Dynamic sticky table propagation",
          metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }
        )

        ReleaseNotes::DiscordClient.stub(:deliver, ->(*) { raise "should not deliver" }) do
          post api_v1_release_notes_path,
               params: {
                 app: "mcritchie-studio",
                 environment: "production",
                 release: "v71",
                 sha: "ef693ab1abc",
                 url: "https://mcritchie.studio/",
                 checks: ["production /up 200", "/signin 200"],
                 task_slugs: [task.slug],
                 dry_run: true
               },
               headers: @headers,
               as: :json
        end

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal false, body.dig("data", "delivered")
        assert_equal true, body.dig("data", "dry_run")
        assert_includes body.dig("data", "message"), "🚀 Production deployed: McRitchie Studio v71 (ef693ab)"
        assert_includes body.dig("data", "message"), "• [Dynamic sticky table propagation](https://mcritchie.studio/tasks/task-ddd444)"
      end

      test "delivers release notes when not a dry run" do
        task = tasks(:queued_task)
        task.update!(
          title: "Admin users sticky table header",
          metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }
        )
        delivered = []

        ReleaseNotes::DiscordClient.stub(:deliver, ->(content:) { delivered << content }) do
          post api_v1_release_notes_path,
               params: {
                 app: "mcritchie-studio",
                 environment: "production",
                 release: "v72",
                 sha: "abcdef0123",
                 url: "https://mcritchie.studio/",
                 checks: "production /up 200",
                 tasks: task.slug
               },
               headers: @headers,
               as: :json
        end

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal true, body.dig("data", "delivered")
        assert_equal ["task-bbb222"], body.dig("data", "task_slugs")
        assert_equal 1, delivered.size
        assert_includes delivered.first, "Admin users sticky table header"
      end

      test "rejects missing task slugs" do
        post api_v1_release_notes_path,
             params: { app: "mcritchie-studio", dry_run: true },
             headers: @headers,
             as: :json

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_equal "MISSING_TASKS", body["error_code"]
      end

      test "rejects unknown task slugs" do
        post api_v1_release_notes_path,
             params: {
               app: "mcritchie-studio",
               release: "v72",
               sha: "abcdef0",
               url: "https://mcritchie.studio/",
               task_slugs: ["task-missing"],
               dry_run: true
             },
             headers: @headers,
             as: :json

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_equal "UNKNOWN_TASKS", body["error_code"]
      end

      test "reports missing webhook for live delivery" do
        task = tasks(:new_task)
        ReleaseNotes::DiscordClient.stub(:deliver, ->(content:) { raise ReleaseNotes::DiscordClient::MissingWebhook, "Release notes webhook is not configured" }) do
          post api_v1_release_notes_path,
               params: {
                 app: "mcritchie-studio",
                 release: "v72",
                 sha: "abcdef0",
                 url: "https://mcritchie.studio/",
                 task_slugs: [task.slug]
               },
               headers: @headers,
               as: :json
        end

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_equal "MISSING_WEBHOOK", body["error_code"]
      end
    end
  end
end
