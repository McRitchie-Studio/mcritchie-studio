require "test_helper"

module Api
  module V1
    # [integration] the change-card endpoints' auth and refusals over HTTP
    # (ChangeBuilds; the happy path runs in test/integration/change_build_launcher_loop_test.rb).
    class ChangeBuildsControllerTest < ActionDispatch::IntegrationTest
      setup do
        token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
        @auth = { "Authorization" => "Bearer #{token}" }
      end

      test "the list, the claim and the finish need a bearer token" do
        get api_v1_change_builds_url
        assert_response :unauthorized
        post claim_api_v1_change_build_url("x"), params: { worker: "w", run: "r" }, as: :json
        assert_response :unauthorized
        post finish_api_v1_change_build_url("x"), params: { run: "r", outcome: "started" }, as: :json
        assert_response :unauthorized
      end

      test "the list answers the candidates and max_attempts" do
        get api_v1_change_builds_url, headers: @auth
        assert_response :success
        body = response.parsed_body
        assert_equal [], body["data"]
        assert_equal ChangeBuilds.max_attempts, body.dig("meta", "max_attempts")
      end

      test "a claim of a card that is not a startable change card answers 409 and changes nothing" do
        task = Task.create!(title: "Plain card", slug: "plain-card", stage: "designed", priority: 1)
        post claim_api_v1_change_build_url(task.slug), params: { worker: "w", run: "r" }, headers: @auth, as: :json

        assert_response :conflict
        assert_equal "NOT_A_CANDIDATE", response.parsed_body["error_code"]
        assert_nil task.reload.devops["change_build"]
      end

      test "an unknown outcome is a 400 and a finish without a held start is a 409" do
        Task.create!(title: "Plain card", slug: "plain-card", stage: "designed", priority: 1)
        post finish_api_v1_change_build_url("plain-card"), params: { run: "r", outcome: "shipped" }, headers: @auth, as: :json
        assert_response :bad_request
        post finish_api_v1_change_build_url("plain-card"), params: { run: "r", outcome: "started" }, headers: @auth, as: :json
        assert_response :conflict
        assert_equal "NOT_HELD", response.parsed_body["error_code"]
      end
    end
  end
end
