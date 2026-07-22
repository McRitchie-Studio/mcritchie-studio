# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    # [integration] POST /api/v1/tasks/claim_next_review — the ATOMIC review pop.
    # End to end through the real green-CI fold: CI verdicts come from seeded
    # GithubWorkflowRun rows (never a live `gh` call), the endpoint claims the
    # highest-ranked reviewable GREEN-CI task and stamps the review lease, and an
    # empty pop is a normal 200 (claimed: null), not an error.
    class ClaimNextReviewTest < ActionDispatch::IntegrationTest
      REPO = "amcritchie/mcritchie-studio"

      setup do
        GithubWorkflowRun.delete_all
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      test "[integration] pops the highest-ranked green task and stamps the claim" do
        low  = submitted("low green task", position: 100, branch: "feat/low",  pr: 1)
        high = submitted("high green task", position: 300, branch: "feat/high", pr: 2)
        seed_green(branch: "feat/low",  sha: "sha-low")
        seed_green(branch: "feat/high", sha: "sha-high")

        claim_next(session: "A", nonce: "a", label: "Gastly")
        assert_response :ok
        body = response.parsed_body.fetch("data")

        assert_equal high.slug, body.dig("claimed", "slug"), "the top-ranked green task is popped"
        assert_equal "https://github.com/amcritchie/mcritchie-studio/pull/2", body.dig("claimed", "pr_url")
        assert_equal "Gastly", body.dig("holder", "label")

        claim = TaskReviewClaim.find_by(task_slug: high.slug)
        assert_equal "A", claim.claimed_session
        assert_equal "a", claim.claim_nonce
        assert_not_nil claim.acquired_at
        assert low.reload && TaskReviewClaim.find_by(task_slug: low.slug).nil?, "only the popped task is claimed"
      end

      test "[integration] skips a red-CI task and claims the green one" do
        red   = submitted("red top task", position: 300, branch: "feat/red",   pr: 3)
        green = submitted("green next task", position: 200, branch: "feat/green", pr: 4)
        seed_run(branch: "feat/red",   sha: "sha-red",   status: "completed", conclusion: "failure")
        seed_green(branch: "feat/green", sha: "sha-green")

        claim_next(session: "A", nonce: "a")
        assert_response :ok
        assert_equal green.slug, response.parsed_body.dig("data", "claimed", "slug")
        assert_nil TaskReviewClaim.find_by(task_slug: red.slug), "the red-CI task is never claimed"
      end

      test "[integration] claimed:null with a reason when nothing is eligible" do
        submitted("red only task", position: 100, branch: "feat/red-only", pr: 5)
        seed_run(branch: "feat/red-only", sha: "sha-red-only", status: "completed", conclusion: "failure")

        claim_next(session: "A", nonce: "a")
        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert_nil body["claimed"], "an empty pop is claimed: null, not an error"
        assert_equal "no_green_ci", body["reason"]
      end

      test "[integration] claimed:null none_reviewable when the board has nothing submitted" do
        claim_next(session: "A", nonce: "a")
        assert_response :ok
        assert_nil response.parsed_body.dig("data", "claimed")
        assert_equal "none_reviewable", response.parsed_body.dig("data", "reason")
      end

      test "[integration] a second caller pops a DIFFERENT task than the first" do
        submitted("first pop task", position: 300, branch: "feat/one", pr: 6)
        submitted("second pop task", position: 200, branch: "feat/two", pr: 7)
        seed_green(branch: "feat/one", sha: "sha-one")
        seed_green(branch: "feat/two", sha: "sha-two")

        claim_next(session: "A", nonce: "a")
        first = response.parsed_body.dig("data", "claimed", "slug")
        claim_next(session: "B", nonce: "b")
        second = response.parsed_body.dig("data", "claimed", "slug")

        refute_nil first
        refute_nil second
        refute_equal first, second, "the second pop advances past the first's claim"
      end

      test "[integration] the endpoint requires bearer auth" do
        post claim_next_review_api_v1_tasks_path, params: { session: "A", nonce: "a" }, as: :json
        assert_response :unauthorized
      end

      private

      def claim_next(session:, nonce:, label: nil)
        post claim_next_review_api_v1_tasks_path,
             params: { session: session, nonce: nonce, label: label },
             headers: @headers, as: :json
      end

      def submitted(title, position:, branch:, pr:)
        Task.create!(
          title: title, stage: "submitted", position: position,
          metadata: { "devops" => {
            "branch" => branch,
            "repositories" => ["mcritchie-studio"],
            "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/#{pr}"
          } }
        )
      end

      def seed_green(branch:, sha:)
        seed_run(branch: branch, sha: sha, status: "completed", conclusion: "success")
      end

      def seed_run(branch:, sha:, status:, conclusion:)
        GithubWorkflowRun.create!(
          repo: REPO, workflow_name: "CI", run_id: SecureRandom.random_number(10**12),
          status: status, conclusion: conclusion,
          head_branch: branch, head_sha: sha, run_started_at: Time.current
        )
      end
    end
  end
end
