require "test_helper"
require_relative "../../../support/client_bundle_fixtures"

module Api
  module V1
    # [integration] POST /api/v1/client_bundles/:sub: an agent session publishes a
    # client app's bundle (docs/agents/system/client-app-host.md). Admin publishes
    # any client app; a studio session only the app whose build task it holds.
    class ClientBundlesControllerTest < ActionDispatch::IntegrationTest
      include ClientBundleFixtures

      setup do
        @app = client_app_with_build_task!
        @task = tasks(:new_task)
        @admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        @builder = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")
        other = tasks(:queued_task)
        other.update_columns(stage: "building")
        @stranger = AgentSession.issue_studio!(soul: "pokemon", task: other, issued_by: "task_claim")
      end

      def payload(files = bundle_files)
        { files: files.map { |path, bytes| { path: path, content_base64: Base64.strict_encode64(bytes) } } }
      end

      def publish(headers, sub: "pawsome", body: payload)
        post api_v1_client_bundle_path(sub), params: body.to_json,
                                             headers: headers.merge("Content-Type" => "application/json")
      end

      def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
      def legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}" }
      def body = JSON.parse(response.body)

      test "[integration] the build task's studio session publishes and flips the version" do
        publish(bearer(@builder))

        assert_response :created
        data = body["data"]
        assert_equal "pawsome", data["app_slug"]
        assert_equal data["version"], @app.reload.preview_version
        assert_equal 4, data["file_count"]
        assert_equal({ "task_slug" => @task.slug, "name" => "preview_ready" }, data["event"].slice("task_slug", "name"))
        assert_equal "pokemon (#{@builder.slug})", @app.current_preview.published_by
      end

      test "[integration] an admin session publishes any client app" do
        publish(bearer(@admin))
        assert_response :created
      end

      test "[integration] publishing needs agent auth: none, the shared token and another task's session are refused" do
        publish({})
        assert_response :unauthorized

        publish(legacy)
        assert_response :unauthorized
        assert_equal "SESSION_REQUIRED", body["error_code"]

        publish(bearer(@stranger))
        assert_response :forbidden
        assert_match(/build task/, body["error"])

        assert_nil @app.reload.preview_version
      end

      test "[integration] an invalid bundle answers 422 with every reason and writes nothing" do
        assert_no_difference "ErrorLog.count" do
          publish(bearer(@builder), body: payload({ "server.rb" => "puts 1", "../x.html" => "x" }))
        end

        assert_response :unprocessable_entity
        assert_equal "BUNDLE_INVALID", body["error_code"]
        assert(body["errors"].any? { |e| e.include?("index.html is required") })
        assert(body["errors"].any? { |e| e.include?("server.rb") })
        assert_nil @app.reload.preview_version
      end

      test "[integration] malformed files answer 422, an unknown app 404, an oversized body 413" do
        publish(bearer(@admin), body: { files: [ { path: "index.html", content_base64: "%%%" } ] })
        assert_response :unprocessable_entity
        assert_match(/not base64/, body["errors"].first)

        publish(bearer(@admin), body: { files: "nope" })
        assert_response :unprocessable_entity

        publish(bearer(@admin), sub: "no-such-app")
        assert_response :not_found

        post api_v1_client_bundle_path("pawsome"), params: "x", headers: bearer(@admin).merge(
          "Content-Type" => "application/json", "CONTENT_LENGTH" => (ClientBundlesController::MAX_REQUEST_BYTES + 1).to_s
        )
        assert_response :content_too_large
      end
    end
  end
end
