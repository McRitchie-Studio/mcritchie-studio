# frozen_string_literal: true

require "test_helper"
# The renewer's cadence is the thing that keeps the lease below alive, so the window
# test drives the REAL constant rather than a number retyped here. It lives in bin/lib
# (plain Ruby, so the standalone CLI can load it) and is not on the Rails autoload path.
require_relative "../../bin/lib/shift_renewer"

# Unit coverage for the DevopsShift lease — acquire / renew / release / self-heal,
# reusing the ClaimLease math. The atomic CAS itself (with_lock) is exercised through
# the disposition paths; true concurrency is covered by the controller integration test.
class DevopsShiftTest < ActiveSupport::TestCase
  A = { session: "sess-A", nonce: "inst-A" }.freeze
  B = { session: "sess-B", nonce: "inst-B" }.freeze
  RESUME_A2 = { session: "sess-A", nonce: "inst-A2" }.freeze # same session, second terminal

  def acquire(lane: "avi", now: Time.current, label: nil, **who)
    DevopsShift.acquire(lane: lane, session: who[:session], nonce: who[:nonce], label: label, now: now)
  end

  test "a free lane is acquired by the first instance" do
    out = acquire(**A, label: "Exeggcute")
    assert out.acquired
    assert_equal :unclaimed, out.disposition
    assert_equal "sess-A", out.shift.claimed_session
    assert_equal "Exeggcute", out.shift.holder_label
    assert out.shift.live?
  end

  test "a second live instance is refused and sees the holder" do
    acquire(**A, label: "Exeggcute")
    out = acquire(**B)

    refute out.acquired, "the careless second launch must not take the lane"
    assert_equal :held_by_other, out.disposition
    assert_equal "sess-A", out.shift.claimed_session, "still held by A"
    assert_equal "Exeggcute", out.shift.holder_label
  end

  test "a resume of the SAME session in a second terminal is also refused (nonce differs)" do
    acquire(**A)
    out = acquire(**RESUME_A2)
    refute out.acquired, "a second terminal on the same session id is a distinct live instance"
    assert_equal :held_by_other, out.disposition
  end

  test "the same instance re-acquiring renews and preserves acquired_at" do
    t0 = Time.utc(2026, 7, 11, 3, 0, 0)
    first = acquire(**A, now: t0)
    original_acquired = first.shift.acquired_at

    again = acquire(**A, now: t0 + 30)
    assert again.acquired
    assert_equal :same_instance, again.disposition
    assert_equal original_acquired.to_i, again.shift.acquired_at.to_i, "acquired_at is stable across a renew"
    assert_operator again.shift.claim_expires_at, :>, first.shift.claim_expires_at, "the lease was extended"
  end

  test "an EXPIRED lease self-heals — the next launch takes over" do
    t0 = Time.utc(2026, 7, 11, 3, 0, 0)
    acquire(**A, now: t0)
    # B launches AFTER A's lease has lapsed (crashed conductor, no renewal).
    out = acquire(**B, now: t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1, label: "Rotom")
    assert out.acquired, "a lapsed lease is reclaimable"
    assert_equal :expired, out.disposition
    assert_equal "sess-B", out.shift.claimed_session
    assert_equal "Rotom", out.shift.holder_label
  end

  test "renew extends only for the holder, never steals" do
    t0 = Time.utc(2026, 7, 11, 3, 0, 0)
    acquire(**A, now: t0)

    assert DevopsShift.renew(lane: "avi", session: "sess-A", nonce: "inst-A", now: t0 + 10)
    refute DevopsShift.renew(lane: "avi", session: "sess-B", nonce: "inst-B", now: t0 + 10),
           "a non-holder cannot renew (and thus cannot steal via renew)"
    assert_equal "sess-A", DevopsShift.find_by(lane: "avi").claimed_session
  end

  test "release frees the lane only for the holder" do
    acquire(**A)
    refute DevopsShift.release(lane: "avi", session: "sess-B", nonce: "inst-B"), "a non-holder cannot release"
    assert DevopsShift.release(lane: "avi", session: "sess-A", nonce: "inst-A")

    row = DevopsShift.find_by(lane: "avi")
    assert_nil row.claimed_session
    refute row.live?
    # the freed lane is immediately acquirable by anyone
    assert acquire(**B).acquired
  end

  test "different lanes never contend" do
    assert acquire(lane: "avi", **A).acquired
    assert acquire(lane: "steffon", **B).acquired, "a steffon shift coexists with an avi shift"
  end

  test "lane is normalized (case/space) so 'Avi ' and 'avi' are one lane" do
    assert acquire(lane: "Avi ", **A).acquired
    refute acquire(lane: "avi", **B).acquired, "the normalized lane collides"
  end

  # --- [unit] THE PROPERTY: a headless holder RETAINS the lane -------------------
  #
  # The regression, stated as the invariant rather than as the mechanism. On
  # 2026-07-20 two Avi review supervisors ran concurrently and duplicated four
  # reviewer lanes, because the holder was headless (no status line ⇒ no renewal) and
  # its lease lapsed ~120s into a much longer piece of work.
  #
  # This walks a 20-minute work window — ten TTLs — renewing on the RENEWER's cadence
  # (which is what bin/lib/shift_renewer.rb now drives, independent of any UI) and
  # asserts a second instance is refused at EVERY point in it. Note what is NOT here:
  # nothing simulates a status line, because nothing may depend on one.
  test "a headless holder keeps the lane for the whole work window, and a second acquire is refused throughout" do
    t0 = Time.utc(2026, 7, 20, 3, 0, 0)
    ttl = ClaimLease::DEFAULT_TTL_SECONDS
    beat = ShiftRenewer::INTERVAL_SECONDS

    assert acquire(**A, now: t0, label: "Hoothoot").acquired

    work_window = 20.minutes.to_i
    checks = 0
    (beat..work_window).step(beat) do |elapsed|
      now = t0 + elapsed
      # What the detached renewer does, on its own cadence, with no UI in the loop.
      assert DevopsShift.renew(lane: "avi", session: A[:session], nonce: A[:nonce], now: now),
             "the holder's own renewer must keep the lease alive at t+#{elapsed}s"

      out = acquire(**B, now: now)
      refute out.acquired,
             "a second conductor must be REFUSED at t+#{elapsed}s — this is the collision the lease exists to prevent"
      assert_equal :held_by_other, out.disposition
      checks += 1
    end

    assert_operator checks, :>, work_window / ttl,
                    "the window must span several TTLs, or it proves nothing about the lapse"
    assert_equal "sess-A", DevopsShift.find_by(lane: "avi").claimed_session, "still A's shift at the end"
  end

  # The other half, and the reason we did NOT simply make acquire fail closed: a
  # crashed holder must never wedge the lane. Its renewer dies with it, so nothing
  # renews, and the lane is reclaimable one TTL later.
  test "a genuinely dead holder stops renewing and the lane is reclaimable" do
    t0 = Time.utc(2026, 7, 20, 3, 0, 0)
    assert acquire(**A, now: t0).acquired

    dead_at = t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1
    refute DevopsShift.renew(lane: "avi", session: A[:session], nonce: A[:nonce], now: dead_at),
           "a lapsed lease cannot be renewed back to life"

    out = acquire(**B, now: dead_at)
    assert out.acquired, "a crash must never deadlock the lane"
    assert_equal :expired, out.disposition
    assert_equal "sess-B", out.shift.claimed_session
  end

  test "status reports each lane's holder and heartbeat age" do
    t0 = Time.utc(2026, 7, 11, 3, 0, 0)
    acquire(lane: "avi", **A, now: t0, label: "Exeggcute")
    rows = DevopsShift.status(now: t0 + 5)
    avi = rows.find { |r| r["lane"] == "avi" }
    assert avi["live"]
    assert_equal "Exeggcute", avi["label"]
    assert_equal 5, avi["heartbeat_age"]
  end
end
