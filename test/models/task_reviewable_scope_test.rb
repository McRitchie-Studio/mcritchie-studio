# frozen_string_literal: true

require "test_helper"

# The load-bearing query of the per-task review claim: Task.reviewable = submitted
# tasks NOT already under a LIVE review claim. It is a proper SERVER-SIDE scope (a
# NOT EXISTS on task_review_claims), so these assert the SQL, not a Ruby filter: a
# live claim EXCLUDES its task, an expired/released one leaves it INCLUDED, and a
# non-submitted task is never in the set regardless of its claim.
class TaskReviewableScopeTest < ActiveSupport::TestCase
  def submitted(title)
    Task.create!(title: title, stage: "submitted")
  end

  def claim(task, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    TaskReviewClaim.acquire(task_slug: task.slug, session: "sess-R", nonce: "inst-R", now: now, ttl: ttl)
  end

  test "reviewable includes a submitted task with no review claim" do
    task = submitted("Fresh Submitted Review Task")
    assert_includes Task.reviewable, task
  end

  test "reviewable EXCLUDES a submitted task under a live review claim" do
    task = submitted("Task Under Live Review")
    claim(task)
    refute_includes Task.reviewable, task, "a live review claim removes the task from the reviewable set"
  end

  test "reviewable INCLUDES a submitted task whose review claim has expired" do
    now = Time.utc(2026, 7, 21, 5, 0, 0)
    task = submitted("Lapsed Review Claim Task")
    claim(task, now: now)
    # Ask for reviewable AFTER the lease has lapsed (crashed reviewer, no renewal).
    later = now + ClaimLease::DEFAULT_TTL_SECONDS + 1
    assert_includes Task.reviewable(now: later), task, "a lapsed claim frees the task for the next reviewer"
  end

  test "reviewable INCLUDES a submitted task whose review claim was released" do
    task = submitted("Released Review Claim Task")
    claim(task)
    assert TaskReviewClaim.release(task_slug: task.slug, session: "sess-R", nonce: "inst-R")
    assert_includes Task.reviewable, task, "a released claim (null expiry) leaves the task reviewable"
  end

  test "reviewable never includes a non-submitted task even without a claim" do
    designed = Task.create!(title: "Designed Not Submitted Yet", stage: "designed")
    building = Task.create!(title: "Still Building Not Submitted", stage: "building")
    refute_includes Task.reviewable, designed
    refute_includes Task.reviewable, building
  end

  test "reviewable is submitted-scoped: a live-claimed task and a fresh one differ only by the claim" do
    fresh = submitted("Fresh Reviewable Task Two")
    claimed = submitted("Claimed Reviewable Task Two")
    claim(claimed)

    set = Task.reviewable
    assert_includes set, fresh
    refute_includes set, claimed
  end
end
