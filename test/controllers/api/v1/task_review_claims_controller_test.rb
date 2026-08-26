require "test_helper"

module Api
  module V1
    # Integration coverage for the per-task review-claim endpoints, plus the
    # `GET /api/v1/tasks?stage=submitted&reviewable=1` filter they exist to serve.
    class TaskReviewClaimsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
        @task = Task.create!(title: "Review Claim Target", stage: "submitted")
      end

      def acquire(session:, nonce:, slug: @task.slug, label: nil)
        post review_claim_api_v1_task_path(slug),
             params: { session: session, nonce: nonce, label: label },
             headers: @headers, as: :json
      end

      test "[integration] the first session claims a free task for review" do
        acquire(session: "A", nonce: "a", label: "Gastly")
        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert body["acquired"]
        assert_equal "unclaimed", body["disposition"]
        assert_equal "Gastly", body.dig("holder", "label")
      end

      test "[integration] a second session is refused and sees the reviewer" do
        acquire(session: "A", nonce: "a", label: "Gastly")
        acquire(session: "B", nonce: "b")

        assert_response :ok
        body = response.parsed_body.fetch("data")
        refute body["acquired"], "the second pr-review session skips a task already under review"
        assert_equal "held_by_other", body["disposition"]
        assert_equal "Gastly", body.dig("holder", "label"), "the skip message names the reviewer"
        assert body.dig("holder", "live")
      end

      test "[integration] only the holder can renew; a non-holder is a 204 no-op" do
        acquire(session: "A", nonce: "a")

        post review_claim_renew_api_v1_task_path(@task.slug), params: { session: "A", nonce: "a" },
                                                              headers: @headers, as: :json
        assert_response :ok
        assert response.parsed_body.dig("data", "renewed")

        post review_claim_renew_api_v1_task_path(@task.slug), params: { session: "B", nonce: "b" },
                                                              headers: @headers, as: :json
        assert_response :no_content
      end

      test "[integration] release frees the task for the next session" do
        acquire(session: "A", nonce: "a")

        post review_claim_release_api_v1_task_path(@task.slug), params: { session: "A", nonce: "a" },
                                                               headers: @headers, as: :json
        assert_response :ok

        acquire(session: "B", nonce: "b")
        assert response.parsed_body.dig("data", "acquired"), "a released task is immediately claimable"
      end

      test "[integration] a non-holder release is a 204 no-op and does not free the task" do
        acquire(session: "A", nonce: "a")
        post review_claim_release_api_v1_task_path(@task.slug), params: { session: "B", nonce: "b" },
                                                               headers: @headers, as: :json
        assert_response :no_content
        assert TaskReviewClaim.find_by(task_slug: @task.slug).live?, "the task is still held by A"
      end

      test "[integration] status GET reports the reviewer, null when none" do
        get review_claim_status_api_v1_task_path(@task.slug), headers: @headers
        assert_response :ok
        assert_nil response.parsed_body.dig("data", "holder"), "no claim yet ⇒ holder is null"

        acquire(session: "A", nonce: "a", label: "Gastly")
        get review_claim_status_api_v1_task_path(@task.slug), headers: @headers
        assert_response :ok
        assert response.parsed_body.dig("data", "holder", "live")
        assert_equal "Gastly", response.parsed_body.dig("data", "holder", "label")
      end

      test "[integration] acquire requires auth" do
        post review_claim_api_v1_task_path(@task.slug), params: { session: "A", nonce: "a" }, headers: {}, as: :json
        assert_response :unauthorized
      end

      # --- [integration] the query the whole feature exists to serve ---------------
      test "[integration] GET /tasks?stage=submitted&reviewable=1 excludes a live-claimed task" do
        other = Task.create!(title: "Other Submitted Task", stage: "submitted")
        acquire(session: "A", nonce: "a") # claims @task for review

        get api_v1_tasks_path, params: { stage: "submitted", reviewable: "1" }, headers: @headers
        assert_response :ok
        slugs = response.parsed_body.fetch("data").map { |t| t["slug"] }
        assert_includes slugs, other.slug, "an unclaimed submitted task is reviewable"
        refute_includes slugs, @task.slug, "a live-claimed submitted task is NOT reviewable"
      end

      test "[integration] reviewable=1 without stage still returns only submitted tasks" do
        building = Task.create!(title: "Building Not Reviewable", stage: "building")

        get api_v1_tasks_path, params: { reviewable: "1" }, headers: @headers
        assert_response :ok
        slugs = response.parsed_body.fetch("data").map { |t| t["slug"] }
        assert_includes slugs, @task.slug
        refute_includes slugs, building.slug, "reviewable folds in stage=submitted"
      end

      test "[integration] reviewable is a supported index param (not rejected)" do
        get api_v1_tasks_path, params: { reviewable: "1" }, headers: @headers
        assert_response :ok, "reviewable must be in INDEX_PARAMS or the index 400s it"
      end
      # THE API BOUNDARY. The model builds `skipped_ci` and the CLI renders it, but
      # nothing between them proved the controller actually SENDS it — and a field
      # that stops at the boundary is a diagnostic nobody ever sees. Same wiring
      # question as blind_repos, which is serialized two lines above it.
      test "[integration] an empty pop carries what the board held for skipped tasks" do
        Task.create!(title: "Ungreen Skipped Candidate", stage: "submitted",
                     metadata: { "devops" => {
                       "branch" => "feat/ungreen-skipped-candidate",
                       "repositories" => ["mcritchie-studio"],
                       "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/9001"
                     } })

        post claim_next_review_api_v1_tasks_path,
             params: { session: "A", nonce: "a" }, headers: @headers, as: :json

        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert_equal "no_green_ci", body["reason"], "the ungreen candidate must not be claimed"
        entries = body["skipped_ci"]
        refute_nil entries, "skipped_ci never crossed the API — the CLI can render nothing"
        entry = entries.find { |e| e["slug"].to_s.include?("ungreen-skipped-candidate") }
        refute_nil entry, "the skipped candidate is not described in the payload"
        assert entry.key?("state"), "the state is the whole diagnostic"
        assert entry.key?("sha"), "the head is what distinguishes a stale tip from a red build"
      end
    end
  end
end
