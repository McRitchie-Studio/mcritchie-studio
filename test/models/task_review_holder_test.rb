# frozen_string_literal: true

require "test_helper"

# [unit] Task#review_holder — WHO is reviewing this task, the fact that turns
# `review_in_progress` from a boolean naming nobody into a busy set a selector can
# act on (busy-auto-misses-mid-review).
#
# Measured 2026-09-22: bin/reviewer-select logged `busy=-` while the souls it named
# were each mid-review, and the conductor overrode the pick by hand four times. One
# of those overrides spent Avi's QA-owner exclusion on PR #1521. The reviewing soul
# was already ON the claim row — it was simply not reachable from the task index.
#
# THREE STATES, asserted apart, because two of them look identical from the return
# value alone: nil can mean "nobody is reviewing this" or "somebody is, and the
# claim names no soul", and those are OPPOSITE facts for a busy set.
class TaskReviewHolderTest < ActiveSupport::TestCase
  def submitted(title)
    Task.create!(title: title, stage: "submitted")
  end

  def claim(task, reviewer:, now: Time.current, ttl: ClaimLease::REVIEW_TTL_SECONDS)
    TaskReviewClaim.acquire(task_slug: task.slug, session: "sess-H", nonce: "inst-H",
                            reviewer: reviewer, label: "pr-review", now: now, ttl: ttl)
  end

  test "review_holder names the soul holding a live review claim" do
    task = submitted("Task Under Live Review Holder")
    claim(task, reviewer: "carl")

    assert_equal "carl", task.reload.review_holder,
                 "the reviewing soul is the whole point — a busy set cannot exclude a nobody"
  end

  test "review_holder is nil when no claim row exists" do
    assert_nil submitted("Task With No Review Claim").review_holder
  end

  test "review_holder is nil once the claim has LAPSED" do
    now = Time.utc(2026, 9, 22, 5, 0, 0)
    task = submitted("Task With Lapsed Review Claim")
    claim(task, reviewer: "carl", now: now)
    later = now + ClaimLease::REVIEW_TTL_SECONDS + 1

    assert_nil task.reload.review_holder(now: later),
               "a crashed reviewer's lease frees on its TTL; excluding them forever would " \
               "shrink the pool for a review that is not happening"
  end

  test "review_holder is nil once the claim is RELEASED" do
    task = submitted("Task With Released Review Claim")
    claim(task, reviewer: "carl")
    assert TaskReviewClaim.release(task_slug: task.slug, session: "sess-H", nonce: "inst-H").released?

    assert_nil task.reload.review_holder, "a released claim is not a busy soul"
  end

  # THE THIRD STATE. `claim_next_review` can take a claim without naming a reviewer,
  # so a task can be genuinely under review by a soul this field cannot name. It
  # answers nil — the same value as "free" — and the two are told apart by
  # `review_claim_live?` beside it. A caller that reads only this field and concludes
  # "nobody is reviewing" is making the exact mistake this card is about.
  test "a LIVE claim naming no soul reads nil, and is told apart by review_claim_live?" do
    task = submitted("Task Under Unnamed Review Claim")
    claim(task, reviewer: nil)
    task.reload

    assert_nil task.review_holder, "the claim names no soul, so there is no name to give"
    assert task.review_claim_live?,
           "but somebody IS reviewing it — the busy set must report this rather than " \
           "score it as an idle seat"
  end

  test "review_holder reads the preloaded association rather than a fresh query" do
    task = submitted("Task Read Through Preload")
    claim(task, reviewer: "shannon")

    preloaded = Task.where(slug: task.slug).includes(:review_claim).first
    # No query may fire here: the index serves this field for a whole PAGE of tasks,
    # and a per-row find_by would reinstate the N+1 the field exists to remove.
    assert_no_queries { assert_equal "shannon", preloaded.review_holder }
  end

  def assert_no_queries(&block)
    count = 0
    counter = ->(_n, _s, _f, _i, payload) { count += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    assert_equal 0, count, "review_holder fired #{count} quer(ies) against a preloaded association"
  end
end
