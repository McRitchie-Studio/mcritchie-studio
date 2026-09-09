# frozen_string_literal: true

require "test_helper"

# THE GATE, EXERCISED OVER THE WIRE (review-lease-outlives-review).
#
# The unit file (test/models/review_lease_ttl_test.rb) proves the lease MATH. This
# one proves the property the pipeline actually depends on, through the endpoints a
# pr-review session really calls — POST review_claim, the reviewable index the
# server-side pop reads, and POST review_claim/release — with the wall clock moved
# rather than a `now:` handed in. That distinction matters here: every renewal in
# production travels this path, and a claim that survives in the model while the
# controller quietly re-derives a shorter lease would pass the unit file and fail in
# the fleet.
#
# The two halves are both here, because shipping one is trading one failure for
# another:
#   1. NOTHING renews for a full review, and a second session is still refused
#   2. a genuinely dead holder's task still frees, and does so in a bounded window
class ReviewLeaseSurvivesReviewTest < ActionDispatch::IntegrationTest
  # The longest CONTINUOUS review in the measured corpus — the gap the lease must
  # cover unaided. Read from the constant so a re-measurement moves the test with it.
  REVIEW_LENGTH = ClaimLease::MEASURED_REVIEW_WINDOW_SECONDS.fetch(:sitting_max)

  setup do
    @headers = {
      "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
    }
    @task = Task.create!(title: "Long Review Under Way", stage: "submitted")
    @t0 = Time.utc(2026, 9, 8, 14, 0, 0)
  end

  def acquire(session:, nonce:, label: nil)
    post review_claim_api_v1_task_path(@task.slug),
         params: { session: session, nonce: nonce, label: label }, headers: @headers, as: :json
    response.parsed_body.fetch("data")
  end

  def release(session:, nonce:)
    post review_claim_release_api_v1_task_path(@task.slug),
         params: { session: session, nonce: nonce }, headers: @headers, as: :json
  end

  def reviewable_slugs
    get api_v1_tasks_path, params: { stage: "submitted", reviewable: "1" }, headers: @headers
    response.parsed_body.fetch("data").map { |t| t["slug"] }
  end

  # --- HALF ONE ---------------------------------------------------------------

  test "[integration] a review runs its full length with ZERO renewals and keeps its task" do
    travel_to(@t0) { assert acquire(session: "A", nonce: "a", label: "Gastly")["acquired"] }

    # No renew call is made anywhere in this window. This is the crashed-renewer,
    # unreachable-board, slept-laptop case — the one that took the gate down before.
    travel_to(@t0 + REVIEW_LENGTH) do
      refused = acquire(session: "B", nonce: "b")

      refute refused["acquired"],
             "after #{ClaimLease.humanize_age(REVIEW_LENGTH)} of silence the first reviewer still holds the PR"
      assert_equal "held_by_other", refused["disposition"]
      assert refused.dig("holder", "live"), "and the board still reports the holder as live"
      assert_equal "Gastly", refused.dig("holder", "label"), "so the skip message can name them"

      refute_includes reviewable_slugs, @task.slug,
                      "the server-side pop must not offer this PR to a second session mid-review"
    end
  end

  test "[integration] the holder's own renew still lands mid-review, and does not report a heal" do
    travel_to(@t0) { acquire(session: "A", nonce: "a") }

    travel_to(@t0 + REVIEW_LENGTH) do
      post review_claim_renew_api_v1_task_path(@task.slug), params: { session: "A", nonce: "a" },
                                                            headers: @headers, as: :json
      assert_response :ok
      assert_equal "renewed", response.parsed_body.dig("data", "state"),
                   "a beat this late is an ORDINARY renewal now — reporting `reacquired` would mean " \
                   "the lease had been free, which is the whole failure being fixed"
    end
  end

  # --- HALF TWO ---------------------------------------------------------------

  test "[integration] a dead reviewer's task frees for the next session after the TTL" do
    travel_to(@t0) { acquire(session: "A", nonce: "a", label: "Gastly") }

    travel_to(@t0 + ClaimLease::REVIEW_TTL_SECONDS + 1) do
      assert_includes reviewable_slugs, @task.slug, "a crash may never wedge a PR out of review forever"

      taken = acquire(session: "B", nonce: "b", label: "Haunter")
      assert taken["acquired"], "the next pr-review session picks it up"
      assert_equal "expired", taken["disposition"]
      assert_equal "Haunter", taken.dig("holder", "label"), "and the seat is the new holder's, not the dead one's"
    end
  end

  # --- RELEASE SAYS WHICH STATE IT FOUND --------------------------------------

  test "[integration] the clean release reports the state it is in" do
    travel_to(@t0) do
      acquire(session: "A", nonce: "a")
      release(session: "A", nonce: "a")

      assert_response :ok
      assert response.parsed_body.dig("data", "released")
      assert_equal "released", response.parsed_body.dig("data", "state")
      assert_includes reviewable_slugs, @task.slug, "a released claim frees the task at once"
    end
  end

  # The 75-minute review's actual ending, reproduced: the reviewer finishes, releases,
  # and the lease had lapsed underneath. Refusing that release left a stale row on the
  # task — which cost 120s under the old TTL and would cost over three hours now.
  test "[integration] releasing a lease that LAPSED still clears the row, and says it lapsed" do
    travel_to(@t0) { acquire(session: "A", nonce: "a") }

    travel_to(@t0 + ClaimLease::REVIEW_TTL_SECONDS + 1) do
      release(session: "A", nonce: "a")

      assert_response :ok
      assert_equal "released_lapsed", response.parsed_body.dig("data", "state"),
                   "the holder is told the task was FREE for part of the review — not congratulated"
      assert_nil TaskReviewClaim.find_by(task_slug: @task.slug).claimed_session,
                 "and the stale row is gone rather than sitting out another TTL"
    end
  end

  test "[integration] a non-holder's release is still a 204 that writes nothing" do
    travel_to(@t0) do
      acquire(session: "A", nonce: "a")
      release(session: "B", nonce: "b")

      assert_response :no_content
      assert_equal "A", TaskReviewClaim.find_by(task_slug: @task.slug).claimed_session,
                   "release never frees a live review for someone who does not hold it"
    end
  end
end
