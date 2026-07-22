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
        "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/#{position}"
      } }
    )
  end

  def all_green(*tasks)
    tasks.each_with_object({}) { |task, memo| memo[task.slug] = "green" }
  end
end
