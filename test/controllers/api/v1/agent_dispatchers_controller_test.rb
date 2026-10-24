require "test_helper"

module Api
  module V1
    # [integration] bin/dispatcher's minute ping over HTTP: the board's auth,
    # the upsert, the refusal of a worker-less ping, and the read.
    class AgentDispatchersControllerTest < ActionDispatch::IntegrationTest
      setup do
        token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
        @shared = { "Authorization" => "Bearer #{token}" }
      end

      test "a ping needs a bearer token" do
        post ping_api_v1_agent_dispatchers_url, params: { worker: "d1" }, as: :json
        assert_response :unauthorized
      end

      test "a ping upserts the dispatcher's row and the list reads it back" do
        2.times do |i|
          post ping_api_v1_agent_dispatchers_url,
               params: { worker: "d1", host: "alex-mac", souls: %w[ray], running: i, capacity: 5, state: "running",
                         version: "abc1234", started_at: 1.hour.ago.iso8601, unexpected: "ignored" },
               headers: @shared, as: :json
          assert_response :success
        end

        assert_equal 1, AgentDispatcher.count
        assert_equal 1, AgentDispatcher.sole.running

        get api_v1_agent_dispatchers_url, headers: @shared
        assert_response :success
        assert_equal "d1", response.parsed_body["data"].first["worker_id"]
        assert_equal false, response.parsed_body.dig("meta", "silent")
      end

      # [integration] The harness health bin/dispatcher measures each beat
      # (AgentMailbox::HarnessProbe) is stored on the row and read back.
      test "a ping's op, gh and power health is stored, and failing beats are counted" do
        t0 = Time.utc(2026, 10, 24, 18, 0, 0)
        3.times do |i|
          post ping_api_v1_agent_dispatchers_url,
               params: { worker: "d1", host: "alex-mac", souls: %w[ray], op_ok: false, gh_ok: true, power: "battery",
                         harness_measured_at: (t0 + i.minutes).iso8601 },
               headers: @shared, as: :json
          assert_response :success
        end

        row = AgentDispatcher.sole
        assert_equal [ false, true, "battery", 3 ], [ row.op_ok, row.gh_ok, row.power_source, row.harness_failing_beats ]
        assert_equal t0 + 2.minutes, row.harness_checked_at
        data = response.parsed_body["data"]
        assert_equal [ false, true, "battery", 3 ], data.values_at("op_ok", "gh_ok", "power_source", "harness_failing_beats")

        post ping_api_v1_agent_dispatchers_url,
             params: { worker: "d1", op_ok: true, gh_ok: true, power: "ac", harness_measured_at: (t0 + 3.minutes).iso8601 },
             headers: @shared, as: :json
        assert_equal [ true, "ac", 0 ], AgentDispatcher.sole.reload.values_at(:op_ok, :power_source, :harness_failing_beats)
      end

      test "control: a ping without harness keys leaves the health columns alone" do
        post ping_api_v1_agent_dispatchers_url, params: { worker: "d1", host: "alex-mac" }, headers: @shared, as: :json
        assert_response :success
        row = AgentDispatcher.sole
        assert_nil row.op_ok
        assert_nil row.power_source
        assert_equal 0, row.harness_failing_beats
      end

      test "a ping without a worker is a 422 and logs no error" do
        assert_no_difference -> { ErrorLog.count } do
          post ping_api_v1_agent_dispatchers_url, params: { host: "x" }, headers: @shared, as: :json
        end
        assert_response :unprocessable_entity
        assert_equal "WORKER_REQUIRED", response.parsed_body["error_code"]
      end
    end
  end
end
