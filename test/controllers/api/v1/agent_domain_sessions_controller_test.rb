require "test_helper"
require "zlib"
require Rails.root.join("bin/lib/agent_domain_registry").to_s

module Api
  module V1
    # [integration] The warm-session lease over HTTP: the shared token or an
    # admin session only; acquire, a 409 for a second holder, the checkpoint
    # round trip (holder-only), consolidation and release; and a standby's
    # claim answered empty while a primary pings.
    class AgentDomainSessionsControllerTest < ActionDispatch::IntegrationTest
      DOMAIN = "mcritchie_studio".freeze

      setup do
        token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
        @shared = { "Authorization" => "Bearer #{token}" }
        config = YAML.safe_load_file(AgentMailbox::DomainRegistry::PATH, aliases: false)
        config["domains"][DOMAIN]["warm_session"] = true
        AgentProposal.registry = AgentMailbox::DomainRegistry.new(config)
      end

      teardown { AgentProposal.reset_registry! }

      def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
      def path(verb) = "/api/v1/agent_domain_sessions/#{DOMAIN}/#{verb}"

      test "a soul's own session reaches none of it; an admin session and the shared token do" do
        task = Task.create!(title: "Warm Session Auth", slug: "warm-session-auth", stage: "building")
        studio = AgentSession.create!(soul: "avi", tier: "studio", issued_by: "task_claim", task_slug: task.slug)
        post path("acquire"), params: { worker: "w1" }, headers: bearer(studio), as: :json
        assert_response :forbidden

        admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        post path("acquire"), params: { worker: "w1" }, headers: bearer(admin), as: :json
        assert_response :success
        get api_v1_agent_domain_sessions_url, headers: @shared
        assert_equal [ DOMAIN ], response.parsed_body["data"].map { |r| r["domain"] }
        assert_nil response.parsed_body["data"].first["seed_summary"]
      end

      test "acquire, a second holder's 409, the checkpoint round trip, consolidate and release" do
        post path("acquire"), params: { worker: "w1" }, headers: @shared, as: :json
        assert_response :success
        assert_equal "w1", response.parsed_body.dig("data", "holder")

        post path("acquire"), params: { worker: "w2" }, headers: @shared, as: :json
        assert_response :conflict
        assert_equal "LEASE_HELD", response.parsed_body["error_code"]
        assert_equal "w1", response.parsed_body.dig("meta", "holder")

        data = Zlib.gzip("{\"type\":\"user\"}\n")
        post path("checkpoint"), params: { worker: "w1", session_id: "sess-0001", turns: 1, context_tokens: 900,
                                           data: Base64.strict_encode64(data) }, headers: @shared, as: :json
        assert_response :success
        assert_equal [ "sess-0001", 1 ], response.parsed_body["data"].values_at("claude_session_id", "turns")

        get path("checkpoint"), params: { worker: "w2" }, headers: @shared
        assert_response :conflict, "the transcript is the holder's only"
        get path("checkpoint"), params: { worker: "w1" }, headers: @shared
        assert_response :success
        assert_equal data, Base64.strict_decode64(response.parsed_body.dig("data", "data"))

        post path("checkpoint"), params: { worker: "w1", session_id: "sess-0002", data: "%%%" }, headers: @shared, as: :json
        assert_response :unprocessable_entity

        assert_no_difference -> { ErrorLog.count } do
          post path("consolidate"), params: { worker: "w2", text: "x" }, headers: @shared, as: :json
        end
        assert_response :conflict
        post path("consolidate"), params: { worker: "w1", text: "Notes.", source_session_id: "sess-0001" },
                                  headers: @shared, as: :json
        assert_response :success
        assert_equal 2, response.parsed_body.dig("data", "generation")
        assert_equal "Notes.", response.parsed_body.dig("data", "seed_summary")

        post path("release"), params: { worker: "w1" }, headers: @shared, as: :json
        assert_response :success
        assert_nil response.parsed_body.dig("data", "holder")
      end

      test "a standby's claim is empty while a primary pings, without a long poll" do
        AgentDispatcher.ping!({ "worker" => "mac-1", "host" => "mac" })
        AgentDispatcher.ping!({ "worker" => "work-1", "host" => "workmac" })
        AgentDispatcher.set_role!(host: "workmac", role: "standby", domains: [ DOMAIN ])
        AgentMessage.create!(channel: "discord", external_id: "standby-1", channel_ref: "c", thread_key: "t",
                             soul_slug: "avi", status: "received", content: "x")

        post claim_api_v1_agent_messages_url, params: { souls: %w[avi], worker: "work-1", wait: 20 }, headers: @shared, as: :json
        assert_response :success
        assert_nil response.parsed_body["data"]
        assert_equal [ "standby_primary_live", false ], response.parsed_body["meta"].values_at("reason", "waited")

        post ping_api_v1_agent_dispatchers_url, params: { worker: "work-1", host: "workmac" }, headers: @shared, as: :json
        assert_equal [ "standby", true ], [ response.parsed_body.dig("data", "role"), response.parsed_body.dig("meta", "primary_live") ]
      end
    end
  end
end
