require "test_helper"

module Api
  module V1
    # [integration] The surface a soul works the pipeline through: find work,
    # claim it atomically, write back what it wrote, release.
    class ContentsControllerTest < ActionDispatch::IntegrationTest
      setup do
        Content.delete_all
        @content = Content.create!(
          title: "Bills Beat Dolphins 24-17", stage: "idea", workflow: "game_recap",
          game_slug: "buffalo-bills-vs-miami-dolphins",
          game_facts: { "home_score" => 24, "away_score" => 17, "winner_slug" => "buffalo-bills" }
        )
      end

      def auth
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}" }
      end

      test "lists content waiting for work" do
        get api_v1_contents_path, params: { stage: "idea", workflow: "game_recap" }, headers: auth, as: :json

        assert_response :success
        body = JSON.parse(response.body)["data"]
        assert_equal 1, body.length
        assert_equal @content.slug, body.first["slug"]
      end

      # With no `limit` this returned ONE card on a queue of any size — the floor
      # against `limit=0` had become the default. One fixture cannot see that.
      test "a list returns the whole queue, and an explicit limit still caps it" do
        2.upto(3) { |i| Content.create!(title: "Game #{i} Recap", stage: "idea", workflow: "game_recap") }
        query = { stage: "idea", workflow: "game_recap" }

        get api_v1_contents_path, params: query, headers: auth, as: :json
        assert_response :success
        assert_equal 3, JSON.parse(response.body)["data"].length, "an absent limit truncated the queue"

        get api_v1_contents_path, params: query.merge(limit: 2), headers: auth, as: :json
        assert_equal 2, JSON.parse(response.body)["data"].length
      end

      test "show carries the game facts the agent needs to write a true take" do
        get api_v1_content_path(@content.slug), headers: auth, as: :json

        assert_response :success
        data = JSON.parse(response.body)["data"]
        assert_equal 24, data["game_facts"]["home_score"]
        assert_equal "buffalo-bills", data["game_facts"]["winner_slug"]
      end

      test "claim_next hands over a card and stamps the holder" do
        post claim_next_api_v1_contents_path,
             params: { session: "sess-1", agent: "turf-monster", workflow: "game_recap" },
             headers: auth, as: :json

        assert_response :success
        body = JSON.parse(response.body)["data"]
        assert_equal "claimed", body["reason"]
        assert_equal @content.slug, body["claimed"]["slug"]
        assert_equal "turf-monster", @content.reload.claimed_by
      end

      # An empty queue must not look like a failure, or callers retry-storm.
      test "an empty queue answers 200 with a reason, not an error" do
        Content.delete_all

        post claim_next_api_v1_contents_path, params: { session: "s" }, headers: auth, as: :json

        assert_response :success
        body = JSON.parse(response.body)["data"]
        assert_nil body["claimed"]
        assert_equal "none_claimable", body["reason"]
      end

      test "a second session is not handed a held card" do
        post claim_next_api_v1_contents_path, params: { session: "sess-1" }, headers: auth, as: :json
        post claim_next_api_v1_contents_path, params: { session: "sess-2" }, headers: auth, as: :json

        assert_nil JSON.parse(response.body)["data"]["claimed"]
      end

      # Every write below CLAIMS FIRST, because a write is now refused without a
      # live claim. That is the contract, not test scaffolding — the SOP already
      # claims before it writes, and these tests walk the same path.
      def claim!(session: "sess-1")
        post claim_next_api_v1_contents_path, params: { session: session }, headers: auth, as: :json
        session
      end

      test "the agent writes its script back and advances the stage" do
        claim!

        patch api_v1_content_path(@content.slug),
              params: { session: "sess-1", content: {
                script_text: "The Bills did not win this game so much as survive it.",
                scenes: [{ "number" => 1, "description" => "stadium at dusk" }],
                captions: "Survived it 24-17.",
                stage: "script"
              } },
              headers: auth, as: :json

        assert_response :success
        @content.reload
        assert_equal "script", @content.stage
        assert_match "survive it", @content.script_text
        assert_equal 1, @content.scenes.length
      end

      # An agent that could rewrite the scoreline could publish a video about a
      # game that did not happen.
      test "the agent cannot rewrite the recorded scoreline" do
        claim!

        patch api_v1_content_path(@content.slug),
              params: { session: "sess-1",
                        content: { script_text: "x", game_facts: { "home_score" => 99 }, game_slug: "fake" } },
              headers: auth, as: :json

        assert_response :success
        @content.reload
        assert_equal 24, @content.game_facts["home_score"]
        assert_equal "buffalo-bills-vs-miami-dolphins", @content.game_slug
      end

      # --- the lease, enforced on the destructive half -----------------------
      #
      # Release (harmless) checked the session from the first day; update
      # (destructive) did not. A write from a non-holder landed with a 200, so
      # the caller could not even tell it had collided.

      test "a write with no claim at all is refused" do
        patch api_v1_content_path(@content.slug),
              params: { session: "sess-1", content: { script_text: "unclaimed" } },
              headers: auth, as: :json

        assert_response :conflict
        assert_equal "CLAIM_REQUIRED", JSON.parse(response.body)["error_code"]
        assert_nil @content.reload.script_text
      end

      test "a write from a session that does not hold the claim is refused" do
        claim!(session: "sess-1")

        patch api_v1_content_path(@content.slug),
              params: { session: "sess-2", content: { script_text: "stranger's take", stage: "script" } },
              headers: auth, as: :json

        assert_response :conflict
        assert_equal "CLAIM_HELD", JSON.parse(response.body)["error_code"]
        @content.reload
        assert_nil @content.script_text
        assert_equal "idea", @content.stage, "a refused write must not advance the card"
      end

      # Omitting the session must not be a way PAST the check — that is exactly
      # how the release guard failed.
      test "a write that sends no session is refused on a claimed card" do
        claim!(session: "sess-1")

        patch api_v1_content_path(@content.slug),
              params: { content: { script_text: "sessionless" } },
              headers: auth, as: :json

        assert_response :conflict
        assert_equal "CLAIM_REQUIRED", JSON.parse(response.body)["error_code"]
        assert_nil @content.reload.script_text
      end

      # The reachable collision: A claims, A's inference outruns the 30-minute
      # lease, B claims the lapsed card, A's write must not land on B's.
      test "a write on a lapsed lease is refused, even for the original holder" do
        claim!(session: "sess-1")
        @content.reload.update!(claimed_at: (Content::AGENT_CLAIM_LEASE + 1.minute).ago)

        patch api_v1_content_path(@content.slug),
              params: { session: "sess-1", content: { script_text: "late take" } },
              headers: auth, as: :json

        assert_response :conflict
        assert_equal "CLAIM_LAPSED", JSON.parse(response.body)["error_code"]
        assert_nil @content.reload.script_text
      end

      test "release drops the lease" do
        post claim_next_api_v1_contents_path, params: { session: "sess-1" }, headers: auth, as: :json

        post release_api_v1_content_path(@content.slug), params: { session: "sess-1" }, headers: auth, as: :json

        assert_response :success
        assert_nil @content.reload.claimed_at
      end

      test "a stranger releasing a live claim is refused" do
        post claim_next_api_v1_contents_path, params: { session: "sess-1" }, headers: auth, as: :json

        post release_api_v1_content_path(@content.slug), params: { session: "sess-2" }, headers: auth, as: :json

        assert_response :conflict
        assert_equal "CLAIM_HELD", JSON.parse(response.body)["error_code"]
        assert @content.reload.claimed_at.present?
      end

      # The fail-open, at the HTTP seam: a stranger who omitted the session used
      # to force-release a live claim, while the same stranger who sent one was
      # refused. The missing value must fail CLOSED.
      test "a release that sends no session cannot drop a live claim" do
        post claim_next_api_v1_contents_path, params: { session: "sess-1" }, headers: auth, as: :json

        post release_api_v1_content_path(@content.slug), headers: auth, as: :json

        assert_response :conflict
        assert_equal "CLAIM_HELD", JSON.parse(response.body)["error_code"]
        assert @content.reload.claimed_at.present?
      end

      test "rejects an unauthenticated caller" do
        get api_v1_contents_path, as: :json
        assert_response :unauthorized
      end

      test "unknown slug is a 404" do
        get api_v1_content_path("no-such-content"), headers: auth, as: :json
        assert_response :not_found
      end
    end
  end
end
