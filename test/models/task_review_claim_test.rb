# frozen_string_literal: true

require "test_helper"
# The renewer's cadence is the thing that keeps the review lease below alive, so the
# headless-window test drives the REAL constant rather than a number retyped here. It
# lives in bin/lib (plain Ruby, so the standalone CLI can load it) and is not on the
# Rails autoload path.
require_relative "../../bin/lib/shift_renewer"

# Unit coverage for the TaskReviewClaim lease — acquire / renew / release / self-heal,
# reusing the ClaimLease math. The atomic CAS itself (with_lock over the unique index)
# is exercised through the disposition paths AND asserted directly; true concurrency is
# covered by the controller integration test.
class TaskReviewClaimTest < ActiveSupport::TestCase
  SLUG = "task-review-me"
  A = { session: "sess-A", nonce: "inst-A" }.freeze
  B = { session: "sess-B", nonce: "inst-B" }.freeze
  RESUME_A2 = { session: "sess-A", nonce: "inst-A2" }.freeze # same session, second terminal

  def acquire(task_slug: SLUG, now: Time.current, label: nil, **who)
    TaskReviewClaim.acquire(task_slug: task_slug, session: who[:session], nonce: who[:nonce], label: label, now: now)
  end

  test "a free task is claimed for review by the first instance" do
    out = acquire(**A, label: "Gastly")
    assert out.acquired
    assert_equal :unclaimed, out.disposition
    assert_equal "sess-A", out.claim.claimed_session
    assert_equal "Gastly", out.claim.holder_label
    assert out.claim.live?
  end

  test "a second live instance is refused and sees the reviewer" do
    acquire(**A, label: "Gastly")
    out = acquire(**B)

    refute out.acquired, "a second pr-review session must not take a task already under review"
    assert_equal :held_by_other, out.disposition
    assert_equal "sess-A", out.claim.claimed_session, "still held by A"
    assert_equal "Gastly", out.claim.holder_label
  end

  test "a resume of the SAME session in a second terminal is also refused (nonce differs)" do
    acquire(**A)
    out = acquire(**RESUME_A2)
    refute out.acquired, "a second terminal on the same session id is a distinct live instance"
    assert_equal :held_by_other, out.disposition
  end

  test "the same instance re-acquiring renews and preserves acquired_at" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    first = acquire(**A, now: t0)
    original_acquired = first.claim.acquired_at

    again = acquire(**A, now: t0 + 30)
    assert again.acquired
    assert_equal :same_instance, again.disposition
    assert_equal original_acquired.to_i, again.claim.acquired_at.to_i, "acquired_at is stable across a renew"
    assert_operator again.claim.claim_expires_at, :>, first.claim.claim_expires_at, "the lease was extended"
  end

  test "an EXPIRED lease self-heals — the next pr-review session takes over" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0)
    # B launches AFTER A's lease has lapsed (crashed reviewer, no renewal).
    out = acquire(**B, now: t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1, label: "Haunter")
    assert out.acquired, "a lapsed review lease is reclaimable"
    assert_equal :expired, out.disposition
    assert_equal "sess-B", out.claim.claimed_session
    assert_equal "Haunter", out.claim.holder_label
  end

  test "a change-of-hands after expiry does NOT inherit the prior holder's label" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0, label: "Gastly")
    # B takes over after A's lease lapsed, WITHOUT supplying its own label.
    out = acquire(**B, now: t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1, label: nil)
    assert out.acquired
    assert_equal :expired, out.disposition
    assert_equal "sess-B", out.claim.claimed_session
    assert_nil out.claim.holder_label, "a new holder must not wear the crashed prior holder's label"
  end

  test "a same-instance renew with no label keeps the holder's existing label" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0, label: "Gastly")
    out = acquire(**A, now: t0 + 30, label: nil)
    assert_equal :same_instance, out.disposition
    assert_equal "Gastly", out.claim.holder_label, "a renew keeps the label it was acquired with"
  end

  test "renew extends only for the holder, never steals" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0)

    assert TaskReviewClaim.renew(task_slug: SLUG, session: "sess-A", nonce: "inst-A", now: t0 + 10)
    refute TaskReviewClaim.renew(task_slug: SLUG, session: "sess-B", nonce: "inst-B", now: t0 + 10),
           "a non-holder cannot renew (and thus cannot steal via renew)"
    assert_equal "sess-A", TaskReviewClaim.find_by(task_slug: SLUG).claimed_session
  end

  test "release frees the task only for the holder" do
    acquire(**A)
    refute TaskReviewClaim.release(task_slug: SLUG, session: "sess-B", nonce: "inst-B"), "a non-holder cannot release"
    assert TaskReviewClaim.release(task_slug: SLUG, session: "sess-A", nonce: "inst-A")

    row = TaskReviewClaim.find_by(task_slug: SLUG)
    assert_nil row.claimed_session
    refute row.live?
    # the freed task is immediately claimable by anyone
    assert acquire(**B).acquired
  end

  test "different tasks never contend" do
    assert acquire(task_slug: "task-one", **A).acquired
    assert acquire(task_slug: "task-two", **B).acquired, "a review on one task coexists with a review on another"
  end

  test "task_slug is normalized (whitespace) so ' task-x ' and 'task-x' are one claim" do
    assert acquire(task_slug: " task-x ", **A).acquired
    refute acquire(task_slug: "task-x", **B).acquired, "the normalized slug collides"
  end

  # --- [unit] THE PROPERTY: a headless reviewer RETAINS the task ----------------
  #
  # The invariant the whole feature rests on, stated as a property rather than a
  # mechanism: a pr-review supervisor that is headless (no status line ⇒ no UI
  # renewal) must still keep its task for the review's whole life, so a second
  # parallel session is refused throughout and never double-reviews.
  #
  # This walks a 20-minute review window — ten TTLs — renewing on the RENEWER's
  # cadence (bin/lib/shift_renewer.rb, independent of any UI) and asserts a second
  # instance is refused at EVERY point in it.
  test "a headless reviewer keeps the task across the whole review window, second acquire refused throughout" do
    t0 = Time.utc(2026, 7, 21, 4, 0, 0)
    ttl = ClaimLease::DEFAULT_TTL_SECONDS
    beat = ShiftRenewer::INTERVAL_SECONDS

    assert acquire(**A, now: t0, label: "Gengar").acquired

    work_window = 20.minutes.to_i
    checks = 0
    (beat..work_window).step(beat) do |elapsed|
      now = t0 + elapsed
      assert TaskReviewClaim.renew(task_slug: SLUG, session: A[:session], nonce: A[:nonce], now: now),
             "the reviewer's own renewer must keep the review lease alive at t+#{elapsed}s"

      out = acquire(**B, now: now)
      refute out.acquired,
             "a second reviewer must be REFUSED at t+#{elapsed}s — this is the double-review the claim prevents"
      assert_equal :held_by_other, out.disposition
      checks += 1
    end

    assert_operator checks, :>, work_window / ttl,
                    "the window must span several TTLs, or it proves nothing about the lapse"
    assert_equal "sess-A", TaskReviewClaim.find_by(task_slug: SLUG).claimed_session, "still A's review at the end"
  end

  # The other half, and the reason we did NOT make acquire fail closed: a crashed
  # reviewer must never wedge a task. Its renewer dies with it, so nothing renews,
  # and the task is reclaimable one TTL later.
  test "a genuinely dead reviewer stops renewing and the task is reclaimable" do
    t0 = Time.utc(2026, 7, 21, 4, 0, 0)
    assert acquire(**A, now: t0).acquired

    dead_at = t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1
    refute TaskReviewClaim.renew(task_slug: SLUG, session: A[:session], nonce: A[:nonce], now: dead_at),
           "a lapsed lease cannot be renewed back to life"

    out = acquire(**B, now: dead_at)
    assert out.acquired, "a crash must never deadlock a task"
    assert_equal :expired, out.disposition
    assert_equal "sess-B", out.claim.claimed_session
  end

  # --- [unit] THE ATOMIC GUARD: the unique index is what makes acquire a CAS ------
  #
  # acquire's correctness (two racers → exactly one winner) rests on ONE row per
  # task_slug taken under with_lock. If the unique index were ever dropped, two
  # first-acquirers could both INSERT and both "win". This asserts the DB refuses a
  # second row for the same slug, and that claim_row tolerates that race by re-reading
  # the winner's row instead of raising.
  test "the unique index forbids a second claim row for one task" do
    TaskReviewClaim.create!(task_slug: SLUG)
    assert_raises(ActiveRecord::RecordNotUnique) do
      # bypass the model so we test the DB constraint itself, not the uniqueness validation
      TaskReviewClaim.connection.execute(
        "INSERT INTO task_review_claims (task_slug, created_at, updated_at) " \
        "VALUES ('#{SLUG}', NOW(), NOW())"
      )
    end
  end

  test "claim_row tolerates the create race and returns the single winning row" do
    first = TaskReviewClaim.claim_row(SLUG)
    second = TaskReviewClaim.claim_row(SLUG)
    assert_equal first.id, second.id, "both first-acquirers converge on ONE row (the unique index enforces it)"
  end

  test "status_for reports the reviewer and heartbeat age, nil when never claimed" do
    assert_nil TaskReviewClaim.status_for("never-claimed")

    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0, label: "Gastly")
    info = TaskReviewClaim.status_for(SLUG, now: t0 + 5)
    assert info["live"]
    assert_equal "Gastly", info["label"]
    assert_equal 5, info["heartbeat_age"]
  end
end
