# frozen_string_literal: true

require "test_helper"
# The renewer's cadence is a load-bearing input to the argument below (the TTL is
# NOT re-derived from it), so the test drives the real constant. It lives in bin/lib
# — plain Ruby, so the standalone CLI can load it — and is not on the autoload path.
require_relative "../../bin/lib/shift_renewer"

# THE REVIEW LEASE MUST OUTLIVE THE REVIEW (review-lease-outlives-review).
#
# The per-task review claim carries a gate property — at most one live reviewer per
# submitted PR — and until 2026-09-08 it carried it on the SHARED 120-second build
# lease. Against reviews measured that day at 40 to 90 minutes, that made the whole
# guarantee rest on an unbroken chain of ~180 renewal beats: miss four to a board
# deploy, a throttled API or a slept laptop, and the lease lapsed SILENTLY while the
# reviewer worked on. Two reviews that day ended with a `release` that no-op'd because
# the holder had changed underneath them.
#
# PR #1300 fixed the renewer (one falsy beat used to exit it permanently). This file
# pins the part #1300 did not reach: the LEASE ITSELF now covers a real review with
# ZERO renewals, so the renewer is redundancy rather than the guarantee.
#
# BOTH HALVES ARE PINNED HERE, deliberately, because either alone trades one failure
# for another:
#   1. a live reviewer's claim SURVIVES a review-length gap with no renewal at all
#   2. a genuinely DEAD holder's claim still becomes reclaimable in BOUNDED time
class ReviewLeaseTtlTest < ActiveSupport::TestCase
  SLUG = "review-lease-ttl-target"
  A = { session: "sess-A", nonce: "inst-A" }.freeze
  B = { session: "sess-B", nonce: "inst-B" }.freeze

  # The longest CONTINUOUS review the corpus contains — the gap the lease must cover.
  REVIEW_LENGTH = ClaimLease::MEASURED_REVIEW_WINDOW_SECONDS.fetch(:sitting_max)

  setup { Task.create!(title: "Review Lease Ttl Target", slug: SLUG, stage: "submitted") }

  def acquire(now: Time.current, **who)
    TaskReviewClaim.acquire(task_slug: SLUG, session: who[:session], nonce: who[:nonce], now: now)
  end

  # --- HALF ONE: the lease survives a real review, unrenewed ------------------

  test "[unit] a review-length gap with ZERO renewals leaves the claim live and held" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    assert acquire(**A, now: t0).acquired

    # Not one beat lands in this window: the renewer died at acquisition, the board
    # was unreachable, the laptop slept. Whatever the cause, nothing renewed.
    later = t0 + REVIEW_LENGTH
    row = TaskReviewClaim.find_by(task_slug: SLUG)

    assert row.live?(now: later),
           "a #{ClaimLease.humanize_age(REVIEW_LENGTH)} review must not outlive its own lease"
    assert_equal :same_instance, ClaimLease.evaluate(row.claim_hash, **A, now: later),
                 "and the holder must still read as the holder, not as a stranger"
  end

  test "[unit] a SECOND reviewer is still refused a review-length gap later" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    acquire(**A, now: t0)

    refused = acquire(**B, now: t0 + REVIEW_LENGTH)

    refute refused.acquired, "the no-two-reviewers-on-one-PR gate is what the lease exists to hold"
    assert_equal :held_by_other, refused.disposition
    assert_equal "sess-A", TaskReviewClaim.find_by(task_slug: SLUG).claimed_session
  end

  test "[unit] the task stays OUT of the reviewable set across a review-length gap" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    acquire(**A, now: t0)

    task = Task.find_by(slug: SLUG)
    refute_includes Task.reviewable(now: t0 + REVIEW_LENGTH), task,
                    "the server-side pop must not hand this PR to a second session mid-review"
  end

  # THE CONTROL. Delete the new TTL and this test is the one that reddens: the same
  # gap against the OLD shared lease frees the task, which is the bug being fixed.
  # Without it, half one passes for a claim that lapsed in two minutes.
  test "[unit] the same gap against the BUILD lease would have freed the task" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    TaskReviewClaim.acquire(task_slug: SLUG, session: A[:session], nonce: A[:nonce], now: t0,
                            ttl: ClaimLease::DEFAULT_TTL_SECONDS)

    row = TaskReviewClaim.find_by(task_slug: SLUG)
    refute row.live?(now: t0 + REVIEW_LENGTH),
           "this is the defect: a 120s lease is gone long before a real review ends"
    assert acquire(**B, now: t0 + REVIEW_LENGTH).acquired,
           "and a racing reviewer walks straight in"
  end

  # --- HALF TWO: a dead holder still frees, in bounded time -------------------

  test "[unit] a genuinely dead holder's claim becomes reclaimable after the TTL" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    acquire(**A, now: t0)

    dead_at = t0 + ClaimLease::REVIEW_TTL_SECONDS + 1
    row = TaskReviewClaim.find_by(task_slug: SLUG)

    refute row.live?(now: dead_at), "a lease nobody renews must lapse — a crash may not wedge a PR"
    assert_includes Task.reviewable(now: dead_at), Task.find_by(slug: SLUG)
    taken = acquire(**B, now: dead_at)
    assert taken.acquired, "the next pr-review session takes the task"
    assert_equal "sess-B", TaskReviewClaim.find_by(task_slug: SLUG).claimed_session
  end

  # The bound is only a bound if it is SHORT ENOUGH to be one. A TTL stretched to
  # cover the parked tail would wedge a crashed reviewer's PR for the better part of
  # a day, which is trading half one's failure for half two's.
  test "[unit] the recovery bound stays inside a working session" do
    assert_operator ClaimLease::REVIEW_TTL_SECONDS, :<, ShiftRenewer::MAX_LIFETIME_SECONDS,
                    "a lease may never outlast the renewer's own safety cap"
    assert_operator ClaimLease::REVIEW_TTL_SECONDS, :<,
                    ClaimLease::MEASURED_REVIEW_WINDOW_SECONDS.fetch(:parked_p99),
                    "the TTL deliberately does NOT chase the parked band — that band has no ceiling"
    assert_operator ClaimLease::REVIEW_TTL_SECONDS, :<, 4 * 60 * 60,
                    "and it stays under the migration lane's 4h, which has no renewer at all"
  end

  # --- The derivation, checked against the corpus it claims to answer to ------

  test "[unit] the TTL clears the whole measured review band" do
    ClaimLease::MEASURED_REVIEW_WINDOW_SECONDS.slice(:p50, :p75, :p90, :sitting_max).each do |percentile, window|
      assert_operator ClaimLease::REVIEW_TTL_SECONDS, :>, window,
                      "a review at the measured #{percentile} (#{window}s) must fit inside the TTL " \
                      "(#{ClaimLease::REVIEW_TTL_SECONDS}s) with no renewal at all"
    end
  end

  test "[unit] the TTL clears the worst measured sitting by the stated margin" do
    worst = ClaimLease::MEASURED_REVIEW_WINDOW_SECONDS.fetch(:sitting_max)

    assert_operator ClaimLease::REVIEW_TTL_SECONDS, :>=, worst * ClaimLease::REVIEW_TTL_SAFETY_FACTOR,
                    "the margin is the whole argument — a threshold parked ON a noisy tail estimate " \
                    "lapses every time the tail breathes"
  end

  # The bug in one line. Merging these two constants back is the regression, and it
  # would pass every other test in this file if the shared one were raised instead —
  # which is the wrong fix: the build claim's 45s heartbeat wants a short TTL.
  test "[unit] the review lane's TTL is its own, and far longer than the build lane's" do
    assert_operator ClaimLease::REVIEW_TTL_SECONDS, :>, ClaimLease::DEFAULT_TTL_SECONDS * 50,
                    "the review lane protects a unit of WORK, not a rendering terminal"
    assert_equal 120, ClaimLease::DEFAULT_TTL_SECONDS,
                 "and the build/shift lanes keep the short lease their 45s heartbeat is sized for"
  end

  # --- The lease age every surface prints -------------------------------------

  test "[unit] heartbeat_age reads the review lease through the REVIEW ttl" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    acquire(**A, now: t0)
    row = TaskReviewClaim.find_by(task_slug: SLUG)

    assert_equal 60, row.heartbeat_age(now: t0 + 60),
                 "a claim renewed a minute ago is a minute old; reading it through the 120s build " \
                 "TTL would report every fresh review lease as hours stale"
    assert_equal 0, row.heartbeat_age(now: t0)
    assert_equal 60, row.holder_info(now: t0 + 60)["heartbeat_age"], "and the published descriptor agrees"
  end

  # --- RELEASE, which the longer TTL makes load-bearing -----------------------
  #
  # A release that quietly drops nothing used to cost 120 seconds. Against
  # REVIEW_TTL_SECONDS it strands the task for over three hours — and the review most
  # likely to hit it is the LONG one, the very case this TTL exists to serve. So the
  # same four-state honesty PR #1300 gave `renew` is pinned here for `release`.

  test "[unit] the holder releases a lease that had already LAPSED, and is told" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    acquire(**A, now: t0)

    # A review that outran even this TTL (the parked band the renewer, not the lease,
    # is meant to carry) still has to be able to hand its task back.
    lapsed_at = t0 + ClaimLease::REVIEW_TTL_SECONDS + 1
    out = TaskReviewClaim.release(task_slug: SLUG, session: A[:session], nonce: A[:nonce], now: lapsed_at)

    assert out.released?, "clearing our OWN stale row is not a steal — refusing it strands the task"
    assert out.lapsed?, "and the caller must learn the lease was FREE for part of its review"
    assert_equal :released_lapsed, out.state
    assert_nil TaskReviewClaim.find_by(task_slug: SLUG).claimed_session
  end

  test "[unit] a lapsed lease that belongs to SOMEBODY ELSE is not ours to release" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)
    acquire(**A, now: t0)

    out = TaskReviewClaim.release(task_slug: SLUG, session: B[:session], nonce: B[:nonce],
                                  now: t0 + ClaimLease::REVIEW_TTL_SECONDS + 1)

    assert_equal :no_lease, out.state, "B held nothing, so B dropped nothing"
    refute out.released?
    assert_equal "sess-A", TaskReviewClaim.find_by(task_slug: SLUG).claimed_session,
                 "and A's row is left exactly as it was — release never writes for a non-holder"
  end

  test "[unit] release names the four states apart instead of one silence" do
    t0 = Time.utc(2026, 9, 8, 14, 0, 0)

    assert_equal :no_lease,
                 TaskReviewClaim.release(task_slug: "no-such-review-task", **A, now: t0).state,
                 "no claim row at all"

    acquire(**A, now: t0)
    assert_equal :held_by_other,
                 TaskReviewClaim.release(task_slug: SLUG, **B, now: t0 + 5).state,
                 "a LIVE reviewer holds it: nothing dropped, and there is somebody to ask"
    assert_equal :released,
                 TaskReviewClaim.release(task_slug: SLUG, **A, now: t0 + 5).state,
                 "the ordinary clean drop"
    assert_equal :no_lease,
                 TaskReviewClaim.release(task_slug: SLUG, **A, now: t0 + 6).state,
                 "and releasing an already-released row drops nothing, rather than claiming success"
  end

  # --- THE COST OF A LONG TTL, PAID DOWN -------------------------------------
  #
  # A long lease makes a FORGOTTEN release expensive, and the sharpest case is the
  # rework loop: a reviewer bounces a task, the builder fixes it inside the hour, and
  # the resubmission is held out of the review queue by the previous review's claim.
  # Measured on this branch before the fix: 205 minutes, silently.

  test "[unit] a resubmission clears the PREVIOUS review's claim and is reviewable at once" do
    task = Task.find_by(slug: SLUG)
    acquire(**A)
    task.block!(by: "carl", kind: "rework")   # the reviewer bounces it: stage -> building

    task.update!(stage: "submitted")          # the builder reworks and resubmits

    assert_includes Task.reviewable, task,
                    "a stale claim from the last review must not hold the new submission out of the queue"
    assert_nil TaskReviewClaim.find_by(task_slug: SLUG).claimed_session
  end

  # THE CONTROL, and the line this fix must not cross. A bounce is NOT a resubmission:
  # the reviewer who just blocked a task is often still writing feedback against it, so
  # their lease stays. Clearing on the bounce would take a live review's lease away.
  test "[unit] a BOUNCE leaves the reviewer's claim exactly where it was" do
    task = Task.find_by(slug: SLUG)
    acquire(**A)

    task.block!(by: "carl", kind: "rework")

    row = TaskReviewClaim.find_by(task_slug: SLUG)
    assert row.live?, "the bouncing reviewer keeps their lease while they write the feedback"
    assert_equal "sess-A", row.claimed_session
  end

  # The clear is scoped to the ENTRY into `submitted`. Any other move must not touch a
  # claim — a blanket "clear on every save" would be the unconsented steal this file
  # exists to prevent.
  test "[unit] moves that are NOT an entry into submitted leave the claim alone" do
    task = Task.find_by(slug: SLUG)
    acquire(**A)

    task.update!(title: "Review Lease Ttl Target Renamed")
    assert TaskReviewClaim.find_by(task_slug: SLUG).live?, "a non-stage save clears nothing"

    task.update!(stage: "reviewed")
    assert TaskReviewClaim.find_by(task_slug: SLUG).live?,
           "the merge path releases through `release`, which reports what it did — not silently here"
  end
end
