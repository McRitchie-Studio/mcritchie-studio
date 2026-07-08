require "test_helper"

module Api
  module V1
    class GateRunsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "requires a bearer token" do
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/open", as: :json

        assert_response :unauthorized
      end

      test "open creates an in-flight attempt with NO usage payload required" do
        assert_difference -> { GateRun.count }, 1 do
          post "/api/v1/gates/task/#{@task.slug}/g1_cert/open",
               params: { gate: { actor: "carl" } }, headers: @headers, as: :json
        end

        assert_response :created
        run = GateRun.last
        assert_equal "g1_cert", run.key
        assert_equal 1, run.attempt
        assert run.in_flight?
        assert_equal "carl", run.actor
        assert_equal "system", run.source, "source defaults to system (deterministic marker semantics)"
      end

      test "double-open reuses the in-flight attempt" do
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/open", headers: @headers, as: :json

        assert_no_difference -> { GateRun.count } do
          post "/api/v1/gates/task/#{@task.slug}/g1_cert/open", headers: @headers, as: :json
        end
        assert_response :created
      end

      test "open then sops then close is the happy path" do
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/open", headers: @headers, as: :json
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/sops",
             params: { gate: { sop: { sop: "full-suite", result: "pass", duration_ms: 8123 } } },
             headers: @headers, as: :json
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/close",
             params: { success: true, gate: { sops: [{ sop: "dor-check", result: "pass" }] } },
             headers: @headers, as: :json

        assert_response :created
        run = GateRun.last
        assert_equal "passed", run.status
        assert_equal %w[full-suite dor-check], run.sops.map { |s| s["sop"] }
      end

      test "close without success is rejected" do
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/close", headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_equal "MISSING_SUCCESS", response.parsed_body["error_code"]
      end

      test "close with success=false records a failed attempt" do
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/close",
             params: { success: false }, headers: @headers, as: :json

        assert_response :created
        assert_equal "failed", GateRun.last.status
      end

      test "unknown subject 404s without minting rows" do
        assert_no_difference -> { GateRun.count } do
          post "/api/v1/gates/task/not-a-task/g1_cert/open", headers: @headers, as: :json
        end

        assert_response :not_found
      end

      test "unknown gate key 422s" do
        post "/api/v1/gates/task/#{@task.slug}/g9_vibes/open", headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_equal "INVALID_GATE_KEY", response.parsed_body["error_code"]
      end

      test "a release-grain key on a task subject is a grain mismatch" do
        post "/api/v1/gates/task/#{@task.slug}/g3_candidate/open", headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_equal "GATE_GRAIN_MISMATCH", response.parsed_body["error_code"]
      end

      test "release subjects take release-grain gates" do
        release = Release.create!(state: "assembling")

        post "/api/v1/gates/release/#{release.slug}/g3_candidate/open", headers: @headers, as: :json

        assert_response :created
        run = GateRun.last
        assert_equal "release", run.subject_type
        assert_equal release.slug, run.subject_slug
      end

      test "index lists a subject's runs chronologically" do
        post "/api/v1/gates/task/#{@task.slug}/g1_cert/open", headers: @headers, as: :json
        post "/api/v1/gates/task/#{@task.slug}/g2b_light/open", headers: @headers, as: :json

        get "/api/v1/gates/task/#{@task.slug}", headers: @headers, as: :json

        assert_response :ok
        keys = response.parsed_body["data"].map { |r| r["key"] }
        assert_equal %w[g1_cert g2b_light], keys
      end
    end
  end
end
