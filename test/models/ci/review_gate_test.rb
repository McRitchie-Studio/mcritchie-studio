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

    # ── Gem repos name their CI workflow differently ──────────────────────────
    #
    # A GEM repo does not run a workflow called "CI". studio-engine runs "Engine CI"
    # (its own suite) and "Consumer CI" (the downstream apps'). The gate resolved the
    # literal "CI" for every repo, so a gem PR's runs never matched, the sha came back
    # blank, and the verdict was :none — NOT green, forever. claim_next_review then
    # skipped it on every wave, which made every studio-engine PR permanently
    # unclaimable by pr-review and forced a manual merge outside the gate.

    test "[unit] green when a GEM repo's own suite workflow concluded success" do
      task = submitted(branch: "feat/gem-green", pr: 8, repo: "studio-engine")
      seed_run(branch: "feat/gem-green", sha: "sha-gem-green", status: "completed", conclusion: "success",
               repo: "amcritchie/studio-engine", workflow: "Engine CI")

      assert Ci::ReviewGate.green?(task),
             "a gem PR whose own suite CI concluded success must be claimable — it was skipped as :none"
      assert_equal :green, Ci::ReviewGate.verdict(task)[:state]
      assert_equal "sha-gem-green", Ci::ReviewGate.verdict(task)[:sha]
    end

    test "[unit] a GEM repo's failing suite is red, not none" do
      task = submitted(branch: "feat/gem-red", pr: 9, repo: "studio-engine")
      seed_run(branch: "feat/gem-red", sha: "sha-gem-red", status: "completed", conclusion: "failure",
               repo: "amcritchie/studio-engine", workflow: "Engine CI")

      refute Ci::ReviewGate.green?(task)
      assert_equal :red, Ci::ReviewGate.verdict(task)[:state],
                   "a gem's failing suite must READ as red — :none would hide a real failure behind 'no CI'"
    end

    # The name filter is load-bearing in BOTH directions. studio-engine's downstream
    # "Consumer CI" runs on the same commits but is not the gem's own verdict, so it
    # must never satisfy the gate on its own.
    test "[unit] a gem's sibling workflow does not satisfy the gate" do
      task = submitted(branch: "feat/gem-sibling", pr: 10, repo: "studio-engine")
      seed_run(branch: "feat/gem-sibling", sha: "sha-sibling", status: "completed", conclusion: "success",
               repo: "amcritchie/studio-engine", workflow: "Consumer CI")

      refute Ci::ReviewGate.green?(task),
             "Consumer CI is the downstream apps' suite, not the gem's own verdict"
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] an APP repo is still resolved by the plain CI workflow" do
      task = submitted(branch: "feat/app-still-works", pr: 11)
      seed_run(branch: "feat/app-still-works", sha: "sha-app", status: "completed", conclusion: "success")

      assert Ci::ReviewGate.green?(task), "the app path must be unchanged by gem awareness"
    end

    private

    def submitted(branch:, pr:, repo: "mcritchie-studio")
      Task.create!(
        title: "gate demo #{SecureRandom.hex(2)}",
        stage: "submitted",
        metadata: { "devops" => {
          "branch" => branch,
          "repositories" => [repo],
          "pr_url" => "https://github.com/amcritchie/#{repo}/pull/#{pr}"
        } }
      )
    end

    def seed_run(branch:, sha:, status:, conclusion:, run_id: nil, started: Time.current,
                 repo: REPO, workflow: "CI")
      GithubWorkflowRun.create!(
        repo: repo, workflow_name: workflow,
        run_id: run_id || SecureRandom.random_number(10**12),
        status: status, conclusion: conclusion,
        head_branch: branch, head_sha: sha, run_started_at: started
      )
    end
  end
end
