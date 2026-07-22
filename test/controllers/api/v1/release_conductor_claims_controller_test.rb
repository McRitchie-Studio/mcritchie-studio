require "test_helper"

module Api
  module V1
    # Integration coverage for the per-release conductor-claim endpoints (assembler /
    # deployer). Mirrors the task review-claim controller test one lane over: the
    # controller reads params[:slug] + role directly (no Release lookup), so the slug
    # is a plain string here.
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

      test "[integration] acquire requires auth" do
        post conductor_claim_api_v1_release_path(SLUG), params: { role: "assembler", session: "A", nonce: "a" },
                                                        headers: {}, as: :json
        assert_response :unauthorized
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
