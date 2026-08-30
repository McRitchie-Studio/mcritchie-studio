require "test_helper"

module Api
  module V1
    # Integration coverage for the per-release conductor-claim endpoints (assembler /
    # deployer). Mirrors the task review-claim controller test one lane over: the claim
    # actions read params[:slug] + role directly, so the slug is a plain string and most
    # tests here need no Release row at all.
    #
    # `show` is the one exception — it also serves `release_state`, looked up by slug,
    # for the detached renewer's "is this candidate finished" stop condition. A slug
    # with no Release row answers null there, which is why the claim tests below are
    # unaffected by it.
    class ReleaseConductorClaimsControllerTest < ActionDispatch::IntegrationTest
      SLUG = "rel-20260721-test"

      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      def acquire(session:, nonce:, role: "assembler", slug: SLUG, label: nil)
        post conductor_claim_api_v1_release_path(slug),
             params: { role: role, session: session, nonce: nonce, label: label },
             headers: @headers, as: :json
      end

      test "[integration] the first session claims a free (release, role)" do
        acquire(session: "A", nonce: "a", role: "deployer", label: "Machamp")
        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert body["acquired"]
        assert_equal "unclaimed", body["disposition"]
        assert_equal "deployer", body.dig("holder", "role")
        assert_equal "Machamp", body.dig("holder", "label")
      end

      test "[integration] a second session is refused and sees the holder" do
        acquire(session: "A", nonce: "a", label: "Snorlax")
        acquire(session: "B", nonce: "b")

        assert_response :ok
        body = response.parsed_body.fetch("data")
        refute body["acquired"], "the second conductor stands down on a release+role already held"
        assert_equal "held_by_other", body["disposition"]
        assert_equal "Snorlax", body.dig("holder", "label"), "the stand-down message names the holder"
        assert body.dig("holder", "live")
      end

      test "[integration] a same-instance re-acquire succeeds (an interrupted ship resumes)" do
        acquire(session: "A", nonce: "a", role: "deployer")
        acquire(session: "A", nonce: "a", role: "deployer")
        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert body["acquired"], "the same live instance re-acquiring is a renew, not a stand-down"
        assert_equal "same_instance", body["disposition"]
      end

      test "[integration] the two roles on one release are independent claims" do
        acquire(session: "A", nonce: "a", role: "assembler")
        acquire(session: "B", nonce: "b", role: "deployer")
        assert_response :ok
        assert response.parsed_body.dig("data", "acquired"),
               "the deployer claim is a separate row — it coexists with the assembler claim"
      end

      test "[integration] only the holder can renew; a non-holder is a 204 no-op" do
        acquire(session: "A", nonce: "a")

        post conductor_claim_renew_api_v1_release_path(SLUG), params: { role: "assembler", session: "A", nonce: "a" },
                                                              headers: @headers, as: :json
        assert_response :ok
        assert response.parsed_body.dig("data", "renewed")

        post conductor_claim_renew_api_v1_release_path(SLUG), params: { role: "assembler", session: "B", nonce: "b" },
                                                              headers: @headers, as: :json
        assert_response :no_content
      end

      test "[integration] release frees the (release, role) for the next session" do
        acquire(session: "A", nonce: "a", role: "deployer")

        post conductor_claim_release_api_v1_release_path(SLUG), params: { role: "deployer", session: "A", nonce: "a" },
                                                                headers: @headers, as: :json
        assert_response :ok

        acquire(session: "B", nonce: "b", role: "deployer")
        assert response.parsed_body.dig("data", "acquired"), "a released claim is immediately re-claimable"
      end

      test "[integration] a non-holder release is a 204 no-op and does not free the claim" do
        acquire(session: "A", nonce: "a")
        post conductor_claim_release_api_v1_release_path(SLUG), params: { role: "assembler", session: "B", nonce: "b" },
                                                                headers: @headers, as: :json
        assert_response :no_content
        assert ReleaseConductorClaim.find_by(release_slug: SLUG, role: "assembler").live?, "still held by A"
      end

      test "[integration] status GET reports the holder, null when none" do
        get conductor_claim_status_api_v1_release_path(SLUG), params: { role: "assembler" }, headers: @headers
        assert_response :ok
        assert_nil response.parsed_body.dig("data", "holder"), "no claim yet ⇒ holder is null"

        acquire(session: "A", nonce: "a", label: "Snorlax")
        get conductor_claim_status_api_v1_release_path(SLUG), params: { role: "assembler" }, headers: @headers
        assert_response :ok
        assert response.parsed_body.dig("data", "holder", "live")
        assert_equal "Snorlax", response.parsed_body.dig("data", "holder", "label")
      end

      # --- the renewer's completion read -----------------------------------------
      #
      # There is no GET /api/v1/releases/:slug (releases are routed `only: []`), so this
      # nested claim endpoint is the only slug-addressed release read the STANDALONE
      # bin/release CLI has. It carries `release_state` for exactly one reader: the
      # detached renewer, which without it renews a conductor claim over finished work
      # for up to twelve hours and stands down the next `bin/release prepare`.

      test "[integration] status GET serves the release state the renewer stops on" do
        Release.create!(slug: SLUG, branch: "release", state: "shipped")
        get conductor_claim_status_api_v1_release_path(SLUG), params: { role: "deployer" }, headers: @headers
        assert_response :ok
        assert_equal "shipped", response.parsed_body.dig("data", "release_state"),
                     "the renewer cannot ask any other endpoint whether its candidate is over"
      end

      test "[integration] a slug with no release answers a null state, not an error" do
        get conductor_claim_status_api_v1_release_path("__forming__"), params: { role: "assembler" },
                                                                       headers: @headers
        assert_response :ok
        assert_nil response.parsed_body.dig("data", "release_state"),
                   "the __forming__ sentinel is a claim on a candidate still being created; " \
                   "the CLI fails OPEN on null, so a forming claim keeps renewing"
      end

      test "[integration] the state read never disturbs the holder half of the payload" do
        Release.create!(slug: SLUG, branch: "release", state: "assembling")
        acquire(session: "A", nonce: "a", label: "Snorlax")
        get conductor_claim_status_api_v1_release_path(SLUG), params: { role: "assembler" }, headers: @headers
        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert_equal "assembling", body["release_state"]
        assert_equal "Snorlax", body.dig("holder", "label"), "the pre-existing status read is intact"
        assert body.dig("holder", "live")
      end

      # THE DRIFT GUARD, Rails half. ReleaseClaimCli runs STANDALONE and cannot load
      # this model, so it mirrors TERMINAL_STATES as a literal (pinned on its own side in
      # test/lib/release_claim_cli_test.rb). The real risk is a NEW state added to the
      # model that the CLI never hears about: it would be neither terminal nor asserted
      # anywhere, and a renewer would treat it as live forever. Pinning the PARTITION
      # makes that addition fail here, loudly, instead of silently ageing out a claim.
      test "[integration] active and terminal states partition every release state" do
        assert_equal %w[shipped abandoned], Release::TERMINAL_STATES,
                     "ReleaseClaimCli::TERMINAL_STATES mirrors this literal and cannot read it"
        assert_equal Release::STATES.sort, (Release::ACTIVE_STATES + Release::TERMINAL_STATES).sort,
                     "every release state must be either active (keep renewing) or terminal (stop); " \
                     "a new state in neither bucket is a renewer that never exits"
        assert_empty Release::ACTIVE_STATES & Release::TERMINAL_STATES,
                     "a state cannot be both live and finished"
      end

      test "[integration] acquire requires auth" do
        post conductor_claim_api_v1_release_path(SLUG), params: { role: "assembler", session: "A", nonce: "a" },
                                                        headers: {}, as: :json
        assert_response :unauthorized
      end

      # --- OPERATOR-GATED force-reassign -------------------------------------------
      OPERATOR_SECRET = "op-secret-under-test"

      def with_operator_secret(secret = OPERATOR_SECRET)
        prior = ENV["OPERATOR_API_SECRET"]
        ENV["OPERATOR_API_SECRET"] = secret
        yield
      ensure
        if prior.nil?
          ENV.delete("OPERATOR_API_SECRET")
        else
          ENV["OPERATOR_API_SECRET"] = prior
        end
      end

      def reassign(session:, nonce:, role: "assembler", slug: SLUG, label: nil, operator_secret: OPERATOR_SECRET,
                   headers: @headers)
        post conductor_claim_reassign_api_v1_release_path(slug),
             params: { role: role, session: session, nonce: nonce, label: label, operator_secret: operator_secret },
             headers: headers, as: :json
      end

      test "[integration] reassign with the operator secret force-takes a LIVE claim the asker could not acquire" do
        with_operator_secret do
          acquire(session: "A", nonce: "a", label: "Snorlax")
          acquire(session: "B", nonce: "b")
          refute response.parsed_body.dig("data", "acquired"), "precondition: B stands down on A's live claim"

          reassign(session: "B", nonce: "b", label: "Gengar")
          assert_response :ok
          body = response.parsed_body.fetch("data")
          assert body["reassigned"]
          assert_equal "reassigned", body["disposition"]
          assert_equal "Gengar", body.dig("holder", "label")
          assert body.dig("holder", "live")
        end
        # And now the reassigned session holds it — its next acquire is a same-instance renew.
        with_operator_secret do
          acquire(session: "B", nonce: "b")
          assert_equal "same_instance", response.parsed_body.dig("data", "disposition"),
                       "the session asking now owns the claim, so it resumes instead of standing down"
        end
      end

      test "[integration] reassign is refused without the operator secret (not a normal agent steal)" do
        with_operator_secret do
          acquire(session: "A", nonce: "a", label: "Snorlax")
          reassign(session: "B", nonce: "b", operator_secret: nil)
          assert_response :forbidden
          assert_equal "OPERATOR_FORBIDDEN", response.parsed_body["error_code"]
          assert ReleaseConductorClaim.find_by(release_slug: SLUG, role: "assembler").claimed_session == "A",
                 "the bearer alone must not move a live claim"
        end
      end

      test "[integration] reassign is refused with a WRONG operator secret" do
        with_operator_secret do
          acquire(session: "A", nonce: "a")
          reassign(session: "B", nonce: "b", operator_secret: "not-the-secret")
          assert_response :forbidden
          assert_equal "OPERATOR_FORBIDDEN", response.parsed_body["error_code"]
        end
      end

      test "[integration] reassign fails CLOSED when no operator secret is configured (inert override)" do
        prior = ENV.delete("OPERATOR_API_SECRET")
        acquire(session: "A", nonce: "a")
        reassign(session: "B", nonce: "b", operator_secret: "anything")
        assert_response :service_unavailable
        assert_equal "OPERATOR_OVERRIDE_UNCONFIGURED", response.parsed_body["error_code"]
      ensure
        ENV["OPERATOR_API_SECRET"] = prior unless prior.nil?
      end

      test "[integration] reassign still requires the bearer token" do
        with_operator_secret do
          reassign(session: "B", nonce: "b", headers: {})
          assert_response :unauthorized
        end
      end

      test "[integration] reassign refuses a blank session/nonce" do
        with_operator_secret do
          reassign(session: "", nonce: "")
          assert_response :unprocessable_entity
          assert_equal "VALIDATION_FAILED", response.parsed_body["error_code"]
        end
      end

      # The CROSS-RELEASE liveness read — bin/agent-worktree's _ship/_gate reclaim guard.
      test "[integration] the live read reports whether ANY claim for a role is live" do
        get "/api/v1/release_conductor_claims/live", params: { role: "deployer" }, headers: @headers
        assert_response :ok
        refute response.parsed_body.dig("data", "live"), "no claim → not live"
        assert_nil response.parsed_body.dig("data", "holder")

        # a live deployer claim on SOME release
        acquire(session: "A", nonce: "a", role: "deployer", slug: "rel-live-1", label: "Machamp")
        get "/api/v1/release_conductor_claims/live", params: { role: "deployer" }, headers: @headers
        assert_response :ok
        assert response.parsed_body.dig("data", "live"), "a live deployer claim on ANY release → live"
        assert_equal "Machamp", response.parsed_body.dig("data", "holder", "label")

        # a DIFFERENT role is unaffected
        get "/api/v1/release_conductor_claims/live", params: { role: "assembler" }, headers: @headers
        assert_response :ok
        refute response.parsed_body.dig("data", "live"), "the assembler role has no live claim"
      end

      test "[integration] a lapsed deployer claim does NOT read as live" do
        # acquire then let it lapse by expiring the lease directly.
        acquire(session: "A", nonce: "a", role: "deployer", slug: "rel-lapsed")
        ReleaseConductorClaim.find_by(release_slug: "rel-lapsed", role: "deployer")
                             .update!(claim_expires_at: 5.minutes.ago)
        get "/api/v1/release_conductor_claims/live", params: { role: "deployer" }, headers: @headers
        assert_response :ok
        refute response.parsed_body.dig("data", "live"), "a lapsed lease is not a live ship"
      end

      test "[integration] the live read requires auth" do
        get "/api/v1/release_conductor_claims/live", params: { role: "deployer" }, headers: {}
        assert_response :unauthorized
      end
    end
  end
end
