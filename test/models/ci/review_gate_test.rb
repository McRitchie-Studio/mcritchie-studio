# frozen_string_literal: true

require "test_helper"

module Ci
  # [unit] Ci::ReviewGate — the server-side, DB-native "is this task's PR CI concluded
  # GREEN?" gate that POST /api/v1/tasks/claim_next_review pops on. It resolves the
  # task's PR head_sha from the newest ingested `CI` GithubWorkflowRun on its branch,
  # joins the run(s) for that head_sha, and folds them through CiStatus's verdict
  # semantics — never a live `gh` call.
  class ReviewGateTest < ActiveSupport::TestCase
    REPO = "amcritchie/mcritchie-studio"

    setup { GithubWorkflowRun.delete_all }

    test "[unit] green when the CI run for the task's head_sha concluded success" do
      task = submitted(branch: "feat/green", pr: 1)
      seed_run(branch: "feat/green", sha: "sha-green", status: "completed", conclusion: "success")

      assert Ci::ReviewGate.green?(task)
      assert_equal :green, Ci::ReviewGate.verdict(task)[:state]
      assert_equal "sha-green", Ci::ReviewGate.verdict(task)[:sha], "the verdict carries the resolved head_sha"
    end

    test "[unit] red when the CI run concluded failure — never green" do
      task = submitted(branch: "feat/red", pr: 2)
      seed_run(branch: "feat/red", sha: "sha-red", status: "completed", conclusion: "failure")

      refute Ci::ReviewGate.green?(task)
      assert_equal :red, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] pending while the CI run is still in flight — not green" do
      task = submitted(branch: "feat/pending", pr: 3)
      seed_run(branch: "feat/pending", sha: "sha-pending", status: "in_progress", conclusion: nil)

      refute Ci::ReviewGate.green?(task)
      assert_equal :pending, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] none when no CI run has been ingested for the task's branch" do
      task = submitted(branch: "feat/ci-less", pr: 4) # no seed_run

      refute Ci::ReviewGate.green?(task)
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] no_pr when the task carries no PR yet" do
      task = Task.create!(title: "no pr gate", stage: "submitted",
                          metadata: { "devops" => { "branch" => "feat/no-pr", "repositories" => ["mcritchie-studio"] } })

      refute Ci::ReviewGate.green?(task)
      assert_equal :no_pr, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] a green run on a DIFFERENT branch never greens this task (the head_sha join is scoped)" do
      task = submitted(branch: "feat/mine", pr: 5)
      seed_run(branch: "feat/someone-else", sha: "sha-theirs", status: "completed", conclusion: "success")

      refute Ci::ReviewGate.green?(task), "CI for another branch's head must not satisfy this task's gate"
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] a re-run supersedes a stale failed run for the same head_sha" do
      task = submitted(branch: "feat/rerun", pr: 6)
      # Attempt 1 failed; attempt 2 (newer run_id + run_started_at) on the SAME sha is green.
      seed_run(branch: "feat/rerun", sha: "sha-rerun", status: "completed", conclusion: "failure",
               run_id: 100, started: 2.minutes.ago)
      seed_run(branch: "feat/rerun", sha: "sha-rerun", status: "completed", conclusion: "success",
               run_id: 200, started: 1.minute.ago)

      assert Ci::ReviewGate.green?(task), "the freshest run for the head_sha is the live verdict"
    end

    test "[unit] the injected token seam short-circuits the DB read" do
      task = submitted(branch: "feat/inject", pr: 7) # no runs seeded at all

      assert Ci::ReviewGate.green?(task, injected: "green")
      refute Ci::ReviewGate.green?(task, injected: "red")
      assert_equal :pending, Ci::ReviewGate.verdict(task, injected: "pending")[:state]
    end

    private

    def submitted(branch:, pr:)
      Task.create!(
        title: "gate demo #{SecureRandom.hex(2)}",
        stage: "submitted",
        metadata: { "devops" => {
          "branch" => branch,
          "repositories" => ["mcritchie-studio"],
          "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/#{pr}"
        } }
      )
    end

    def seed_run(branch:, sha:, status:, conclusion:, run_id: nil, started: Time.current)
      GithubWorkflowRun.create!(
        repo: REPO, workflow_name: "CI",
        run_id: run_id || SecureRandom.random_number(10**12),
        status: status, conclusion: conclusion,
        head_branch: branch, head_sha: sha, run_started_at: started
      )
    end
  end
end
