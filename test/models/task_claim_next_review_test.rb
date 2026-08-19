# frozen_string_literal: true

require "test_helper"

# [unit] Task.claim_next_review — the ATOMIC review pop: claim the single
# highest-ranked reviewable task whose PR CI concluded GREEN, and stamp the review
# lease on it. The CI verdict is driven through the `ci_status:` injection seam (a
# { slug => token } hash) so these rank/skip cases need no ingested GithubWorkflowRun
# rows; the DB green-CI fold itself is covered by Ci::ReviewGateTest and the endpoint
# integration test. Concurrency (FOR UPDATE SKIP LOCKED) is exercised as its
# SEQUENTIAL proxy here — local tests are single-connection by design (the same proxy
# TaskReviewClaimTest uses): a first pop claims the top, a second pop advances past it.
class TaskClaimNextReviewTest < ActiveSupport::TestCase
  test "[unit] pops the HIGHEST-ranked green task first (position DESC)" do
    low  = submitted("low rank task", position: 100)
    high = submitted("high rank task", position: 300)
    mid  = submitted("mid rank task", position: 200)

    result = Task.claim_next_review(session: "A", nonce: "a", ci_status: all_green(low, high, mid))

    assert result.claimed?
    assert_equal high.slug, result.task.slug, "the top-of-column task is popped first"
    assert_equal "claimed", result.reason
  end

  test "[unit] stamps the review session, nonce, and acquired_at on the claim" do
    task = submitted("stamp me task", position: 100)

    result = Task.claim_next_review(session: "sess-1", nonce: "nonce-1", label: "Gastly",
                                    ci_status: all_green(task))

    claim = result.outcome.claim
    assert_equal "sess-1", claim.claimed_session
    assert_equal "nonce-1", claim.claim_nonce
    assert_equal "Gastly", claim.holder_label
    assert_not_nil claim.acquired_at, "acquired_at is stamped on the claim"
    assert_not_nil claim.claim_expires_at, "the lease expiry is stamped"
    # Persisted, not just in-memory.
    assert_equal "sess-1", TaskReviewClaim.find_by(task_slug: task.slug).claimed_session
  end

  test "[unit] SKIPS a task the popping reviewer BUILT, claiming the next one" do
    # The server-side pop reaches a review without ever calling bin/reviewer-select,
    # so the no-self-review rule has to hold here too — and it must SKIP rather than
    # give up, or one soul's own PR at the top of the column would stall the queue.
    mine = submitted("i built this task", position: 300)
    mine.update!(metadata: mine.metadata.deep_merge("devops" => { "built_by" => "carl" }))
    other = submitted("someone else built this", position: 200)

    result = Task.claim_next_review(session: "A", nonce: "a", reviewer: "carl",
                                    ci_status: all_green(mine, other))

    assert_equal other.slug, result.task.slug, "carl never pops the PR carl built"
    assert_nil TaskReviewClaim.find_by(task_slug: mine.slug)&.claimed_session,
      "and takes no lease on it"
  end

  test "[unit] SKIPS a task already under live review, claiming the next one" do
    held = submitted("held top task", position: 300)
    free = submitted("free next task", position: 200)
    # A DIFFERENT session already reviews the top task.
    TaskReviewClaim.acquire(task_slug: held.slug, session: "X", nonce: "x")

    result = Task.claim_next_review(session: "A", nonce: "a", ci_status: all_green(held, free))

    assert_equal free.slug, result.task.slug, "a task under live review is skipped"
  end

  test "[unit] SKIPS red / pending / none CI tasks and claims the first green one" do
    red     = submitted("red ci task", position: 400)
    pending = submitted("pending ci task", position: 300)
    green   = submitted("green ci task", position: 200)

    result = Task.claim_next_review(
      session: "A", nonce: "a",
      ci_status: { red.slug => "red", pending.slug => "pending", green.slug => "green" }
    )

    assert_equal green.slug, result.task.slug, "only the green-CI task is claimed"
  end

  test "[unit] two sequential callers get DIFFERENT tasks" do
    t1 = submitted("first pop task", position: 300)
    t2 = submitted("second pop task", position: 200)

    a = Task.claim_next_review(session: "A", nonce: "a", ci_status: all_green(t1, t2))
    b = Task.claim_next_review(session: "B", nonce: "b", ci_status: all_green(t1, t2))

    assert a.claimed?
    assert b.claimed?
    refute_equal a.task.slug, b.task.slug, "the second pop advances past the first's claim"
    assert_equal [t1.slug, t2.slug].sort, [a.task.slug, b.task.slug].sort
  end

  test "[unit] the second caller gets null when only one task is eligible" do
    only = submitted("the only eligible task", position: 100)

    a = Task.claim_next_review(session: "A", nonce: "a", ci_status: all_green(only))
    b = Task.claim_next_review(session: "B", nonce: "b", ci_status: all_green(only))

    assert_equal only.slug, a.task.slug
    refute b.claimed?, "the sole task is taken; the next pop is empty"
    assert_nil b.task
    assert_equal "none_reviewable", b.reason
  end

  test "[unit] reason is no_green_ci when reviewable tasks exist but none are green" do
    a = submitted("red only a task", position: 200)
    b = submitted("red only b task", position: 100)

    result = Task.claim_next_review(session: "A", nonce: "a",
                                    ci_status: { a.slug => "red", b.slug => "pending" })

    refute result.claimed?
    assert_equal "no_green_ci", result.reason, "a reviewable-but-ungreen board reports why nothing popped"
  end

  test "[unit] reason is none_reviewable when nothing is submitted" do
    Task.create!(title: "still building task", stage: "building")

    result = Task.claim_next_review(session: "A", nonce: "a")

    refute result.claimed?
    assert_equal "none_reviewable", result.reason
  end

  private

  def submitted(title, position:)
    Task.create!(
      title: title,
      stage: "submitted",
      position: position,
      metadata: { "devops" => {
        "branch" => "feat/#{title.parameterize}",
        "repositories" => ["mcritchie-studio"],
        "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/#{position}"
      } }
    )
  end

  def all_green(*tasks)
    tasks.each_with_object({}) { |task, memo| memo[task.slug] = "green" }
  end

  # ── The real DB fold, no injection seam ──────────────────────────────────────
  #
  # Every case above drives CI through `ci_status:`, which is precisely why none of
  # them caught the gem bug: the injection short-circuits Ci::ReviewGate before it
  # ever resolves a workflow name. These two run the ACTUAL fold against ingested
  # GithubWorkflowRun rows, so a regression in workflow resolution fails here.

  class GemRepoPopTest < ActiveSupport::TestCase
    setup { GithubWorkflowRun.delete_all }

    test "[integration] pops a GEM repo task whose own suite CI is green" do
      task = gem_submitted("engine fix task", position: 100)
      seed_engine_ci(branch: "feat/engine-fix-task", sha: "sha-engine", conclusion: "success")

      result = Task.claim_next_review(session: "S", nonce: "n") # NO injection — real fold

      assert result.claimed?, "a green gem PR must be claimable; it was skipped as no_green_ci"
      assert_equal task.slug, result.task.slug
    end

    test "[integration] does NOT pop a gem task whose own suite CI failed" do
      gem_submitted("engine broken task", position: 100)
      seed_engine_ci(branch: "feat/engine-broken-task", sha: "sha-broken", conclusion: "failure")

      result = Task.claim_next_review(session: "S", nonce: "n")

      refute result.claimed?, "a red gem PR must never be claimed"
      assert_equal "no_green_ci", result.reason
    end

    private

    def gem_submitted(title, position:)
      Task.create!(
        title: title, stage: "submitted", position: position,
        metadata: { "devops" => {
          "branch" => "feat/#{title.parameterize}",
          "repositories" => ["studio-engine"],
          "pr_url" => "https://github.com/McRitchie-Studio/studio-engine/pull/#{position}"
        } }
      )
    end

    def seed_engine_ci(branch:, sha:, conclusion:)
      GithubWorkflowRun.create!(
        repo: "McRitchie-Studio/studio-engine",
        workflow_name: GithubWorkflowRun::GEM_CI_WORKFLOWS.fetch("studio-engine"),
        run_id: SecureRandom.random_number(10**12),
        status: "completed", conclusion: conclusion,
        head_branch: branch, head_sha: sha, run_started_at: Time.current
      )
    end
  end

  # ── A TASK IS ONE CHANGE, EVEN ACROSS TWO REPOS ──────────────────────────────
  #
  # The pop gated on `repositories.first` (Ci::ReviewGate.repo_for), so a task
  # landing PRs in two repos was popped for review on repo #1's green while repo
  # #2 was red or still running — the reviewer then read half a task whose other
  # half was already broken, and armed a merge on that reading.
  #
  # These drive the REAL fold (no `ci_status:` injection, which short-circuits the
  # gate before it resolves a repo at all) and every one of them turns on the
  # SECOND repo, with repo #1 asserted green: a case where only one repo is green
  # passes identically on the broken code.
  class MultiRepoPopTest < ActiveSupport::TestCase
    HUB = "McRitchie-Studio/mcritchie-studio"
    TURF = "McRitchie-Studio/turf-monster"

    setup { GithubWorkflowRun.delete_all }

    test "[integration] does NOT pop a two-repo task whose SECOND repo's CI is red" do
      task = two_repo_submitted("hub and turf red task")
      seed_ci(repo: HUB, branch: task.devops_field("branch"), sha: "sha-hub", conclusion: "success")
      seed_ci(repo: TURF, branch: task.devops_field("branch"), sha: "sha-turf", conclusion: "failure")

      assert_equal :green, Ci::ReviewGate.verdict(task, repo: "mcritchie-studio")[:state],
                   "precondition: repo #1 is green — this is the arrangement that used to pop"

      result = Task.claim_next_review(session: "S", nonce: "n") # NO injection — real fold

      refute result.claimed?, "half a task cannot be reviewed: a red second repo must hold the pop"
      assert_equal "no_green_ci", result.reason
    end

    test "[integration] does NOT pop while the SECOND repo is still running" do
      task = two_repo_submitted("hub and turf pending task")
      seed_ci(repo: HUB, branch: task.devops_field("branch"), sha: "sha-hub", conclusion: "success")
      seed_ci(repo: TURF, branch: task.devops_field("branch"), sha: "sha-turf",
              status: "in_progress", conclusion: nil)

      refute Task.claim_next_review(session: "S", nonce: "n").claimed?,
             "a reviewer claiming now would review against a suite that has not reported"
    end

    # THE POSITIVE CONTROL — a gate that never pops a multi-repo task would strand
    # the release conductor's canonical shape instead of protecting it.
    test "[integration] pops a two-repo task once BOTH repos are green" do
      task = two_repo_submitted("hub and turf green task")
      seed_ci(repo: HUB, branch: task.devops_field("branch"), sha: "sha-hub", conclusion: "success")
      seed_ci(repo: TURF, branch: task.devops_field("branch"), sha: "sha-turf", conclusion: "success")

      result = Task.claim_next_review(session: "S", nonce: "n")

      assert result.claimed?, "both repos concluded success — this task is reviewable"
      assert_equal task.slug, result.task.slug
    end

    # The wiring-gap report reads the same repos the gate does, so the repo that is
    # actually holding the task can be named. It used to report repo #1 — the one
    # repo that WAS delivering — which is a report that answers with the wrong repo.
    test "[integration] blind_repos names the unwired SECOND repo" do
      task = two_repo_submitted("hub green turf unwired task")
      seed_ci(repo: HUB, branch: task.devops_field("branch"), sha: "sha-hub", conclusion: "success")

      result = Task.claim_next_review(session: "S", nonce: "n")

      refute result.claimed?
      assert_includes result.blind_repo_list, "turf-monster",
                      "the repo delivering NO CI is the one to name — the hub is wired and green"
      refute_includes result.blind_repo_list, "mcritchie-studio"
    end

    private

    # PRs in two repos: the hub (the primary `pr_url`) and turf (the per-repo
    # `pr_urls` register `bin/task update --pr-url-for` writes).
    def two_repo_submitted(title, position: 100)
      Task.create!(
        title: title, stage: "submitted", position: position,
        metadata: { "devops" => {
          "branch" => "feat/#{title.parameterize}",
          "repositories" => %w[mcritchie-studio turf-monster],
          "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/#{position}",
          "pr_urls" => {
            "turf-monster" => "https://github.com/McRitchie-Studio/turf-monster/pull/#{position + 1}"
          }
        } }
      )
    end

    def seed_ci(repo:, branch:, sha:, conclusion:, status: "completed")
      GithubWorkflowRun.create!(
        repo: repo, workflow_name: GithubWorkflowRun::CI_WORKFLOW,
        run_id: SecureRandom.random_number(10**12),
        status: status, conclusion: conclusion,
        head_branch: branch, head_sha: sha, run_started_at: Time.current
      )
    end
  end
end
