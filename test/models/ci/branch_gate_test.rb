# frozen_string_literal: true

require "test_helper"

module Ci
  # [unit] Ci::BranchGate — "is this BRANCH's CI concluded green?", the DB-native
  # answer for the one rung nothing used to certify: `accepted`.
  #
  # THE ASYMMETRY THIS FILE EXISTS TO PIN. `green?` and `red?` are NOT complements.
  # `green?` answers "may I credit this branch", so anything short of a concluded
  # success is false. `red?` answers "must I refuse a release", so only an ASSERTED
  # failure is true — :pending and :none are neither. Collapsing them either way is a
  # real defect: make red? mean "not green" and every sweep that races a run wedges
  # the release lane on a fact nobody stated; make green? mean "not red" and an
  # uncertified branch gets credited, which is the silence this class was written to
  # end.
  class BranchGateTest < ActiveSupport::TestCase
    REPO   = "McRitchie-Studio/mcritchie-studio"
    BRANCH = "accepted"

    setup { GithubWorkflowRun.delete_all }

    test "[unit] green when the newest CI run on the branch concluded success" do
      seed_run(branch: BRANCH, sha: "sha-green", status: "completed", conclusion: "success")

      assert Ci::BranchGate.green?(REPO, BRANCH)
      refute Ci::BranchGate.red?(REPO, BRANCH)
      assert_equal "sha-green", Ci::BranchGate.verdict(REPO, BRANCH)[:sha]
    end

    test "[unit] red when the newest CI run on the branch failed" do
      seed_run(branch: BRANCH, sha: "sha-red", status: "completed", conclusion: "failure")

      assert Ci::BranchGate.red?(REPO, BRANCH), "an asserted failure must refuse the promote"
      refute Ci::BranchGate.green?(REPO, BRANCH)
    end

    # THE WEDGE GUARD. A sweep routinely races a run it can wait for or credit later
    # at the pre-QA gate. If pending refused, every such race would abort a release.
    test "[unit] a still-running branch is neither green nor red" do
      seed_run(branch: BRANCH, sha: "sha-pending", status: "in_progress", conclusion: nil)

      refute Ci::BranchGate.green?(REPO, BRANCH), "nothing has concluded, so nothing may be credited"
      refute Ci::BranchGate.red?(REPO, BRANCH),   "a race is not an asserted failure — it must not block"
    end

    # THE SILENCE GUARD, and the mirror of the one above. Before this branch was
    # certified at all there were simply no rows, and "no rows" must never read as
    # permission.
    test "[unit] a branch with nothing ingested is NOT green, and does not block" do
      verdict = Ci::BranchGate.verdict(REPO, BRANCH)

      assert_equal :none, verdict[:state]
      refute Ci::BranchGate.green?(REPO, BRANCH), "an uncertified branch is not a certified one"
      refute Ci::BranchGate.red?(REPO, BRANCH)
    end

    test "[unit] a run on a DIFFERENT branch never answers for this one" do
      seed_run(branch: "feat/something-else", sha: "sha-elsewhere", status: "completed", conclusion: "success")

      refute Ci::BranchGate.green?(REPO, BRANCH)
      assert_equal :none, Ci::BranchGate.verdict(REPO, BRANCH)[:state]
    end

    # FAIL CLOSED on an unresolved suite workflow, mirroring Ci::ReviewGate: a repo
    # with no declared CI workflow must read :none, never "match any run on the
    # branch". An unrelated downstream run once authorised a merge exactly that way.
    test "[unit] an unrelated workflow on the branch does not make it green" do
      seed_run(branch: BRANCH, sha: "sha-unrelated", status: "completed", conclusion: "success",
               workflow: "Consumer CI")

      refute Ci::BranchGate.green?(REPO, BRANCH),
             "only the repo's DECLARED suite workflow carries its verdict"
    end

    test "[unit] a re-run's newer attempt supersedes the older verdict" do
      seed_run(branch: BRANCH, sha: "sha-rerun", status: "completed", conclusion: "failure",
               run_id: 4242, attempt: 1)
      GithubWorkflowRun.find_by(run_id: 4242).update!(conclusion: "success", run_attempt: 2)

      assert Ci::BranchGate.green?(REPO, BRANCH), "the newer attempt is the live verdict"
    end

    test "[unit] a blank repo or branch resolves to none rather than raising" do
      assert_equal :none, Ci::BranchGate.verdict("", BRANCH)[:state]
      assert_equal :none, Ci::BranchGate.verdict(REPO, "")[:state]
    end

    private

    def seed_run(branch:, sha:, status:, conclusion:, run_id: nil, started: Time.current,
                 repo: REPO, workflow: "CI", attempt: 1)
      GithubWorkflowRun.create!(
        repo: repo, workflow_name: workflow,
        run_id: run_id || SecureRandom.random_number(10**12),
        status: status, conclusion: conclusion, run_attempt: attempt,
        head_branch: branch, head_sha: sha, run_started_at: started
      )
    end
  end
end
