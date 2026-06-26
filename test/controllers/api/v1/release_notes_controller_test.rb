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

      test "delivers rich embeds when not a dry run" do
        task = tasks(:queued_task)
        task.update!(
          title: "Admin users sticky table header",
          metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }
        )
        delivered = []

        # The happy path must NOT touch ErrorLog — we only log delivery failures.
        assert_no_difference -> { ErrorLog.count } do
          ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { delivered << { content: content, embeds: embeds } }) do
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
        end

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal true, body.dig("data", "delivered")
        assert_equal true, body.dig("data", "embedded")
        assert_equal ["task-bbb222"], body.dig("data", "task_slugs")
        assert_equal 1, delivered.size
        payload = delivered.first
        embeds = payload[:embeds]
        assert embeds.present?, "the controller hands rich embeds to the client"
        assert(embeds.any? { |embed| embed[:title] == "Admin users sticky table header" }, "the task card carries the title")
        # The deploy header now rides in `content` (H1 + H3 masked link), not as a
        # summary embed.
        assert_equal "# 🚀 Production Deployment\n### [v72 🪎](https://mcritchie.studio/)", payload[:content]
        refute(embeds.any? { |embed| embed[:title].to_s.include?("deployed") }, "no summary embed is emitted")
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

      test "reports missing webhook for live delivery and records it to ErrorLog" do
        task = tasks(:new_task)
        assert_difference -> { ErrorLog.count }, 1 do
          ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { raise ReleaseNotes::DiscordClient::MissingWebhook, "Release notes webhook is not configured" }) do
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
        end

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_equal "MISSING_WEBHOOK", body["error_code"]
        # The delivery failure surfaces on the board, not just as an API error.
        assert_equal "Release notes webhook is not configured", ErrorLog.last.message
      end

      test "reports a discord delivery error for live delivery and records it to ErrorLog" do
        task = tasks(:new_task)
        assert_difference -> { ErrorLog.count }, 1 do
          ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { raise ReleaseNotes::DiscordClient::DeliveryError, "Discord returned 500" }) do
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
        end

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_equal "DISCORD_DELIVERY_FAILED", body["error_code"]
        assert_equal "Discord returned 500", ErrorLog.last.message
      end

      test "a dry run delivery failure is impossible, so nothing is logged" do
        task = tasks(:new_task)
        assert_no_difference -> { ErrorLog.count } do
          post api_v1_release_notes_path,
               params: {
                 app: "mcritchie-studio",
                 release: "v72",
                 sha: "abcdef0",
                 url: "https://mcritchie.studio/",
                 task_slugs: [task.slug],
                 dry_run: true
               },
               headers: @headers,
               as: :json
        end

        assert_response :success
      end
    end
  end
end
