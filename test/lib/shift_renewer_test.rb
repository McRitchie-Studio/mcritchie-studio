# frozen_string_literal: true

# [unit] tests for bin/lib/shift_renewer.rb — the loop that keeps a devops SHIFT
# lease alive for as long as the holder is actually working.
#
# THE BUG THIS FILE EXISTS FOR (confirmed by experiment 2026-07-20): renewal used to
# live ONLY in bin/statusline, so it was a property of the UI, not of the run. Any
# session without a status line — a background agent run, and critically the
# AUTONOMOUS HEARTBEAT — stopped renewing the moment it acquired, its lease lapsed
# one TTL later, and `bin/devops-shift acquire` then reported the lane FREE to a
# second session. Two Avi review supervisors duplicated four reviewer lanes on
# PR #601 that way — the exact collision the lease exists to prevent.
#
# So the renewer is anchored to the ANCHOR PROCESS (the long-lived claude/codex
# process the lease identity is already derived from), never to a rendered UI:
#   anchor alive  ⇒ keep renewing, headless or not
#   anchor gone   ⇒ STOP, so the lease lapses and a crash can never wedge the lane
#
#   ruby -Itest test/lib/shift_renewer_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/shift_renewer"
require_relative "../../lib/claim_lease"

class ShiftRenewerTest < Minitest::Test
  # A scripted run: `alive` answers from a queue, every renew succeeds unless the
  # renew queue says otherwise, and sleeping only advances a fake clock.
  def run_loop(alive:, renew: [], interval: 30, max_lifetime: 3600)
    slept = []
    now = Time.utc(2026, 7, 20, 12, 0, 0)
    renews = 0
    outcome = ShiftRenewer.run(
      alive: -> { alive.empty? ? true : alive.shift },
      renew: -> { renews += 1; renew.empty? ? true : renew.shift },
      sleeper: ->(s) { slept << s; now += s },
      clock: -> { now },
      interval: interval,
      max_lifetime: max_lifetime
    )
    { outcome: outcome, renews: renews, slept: slept }
  end

  # --- the regression: a HEADLESS holder keeps renewing --------------------------

  def test_unit_a_headless_holder_keeps_renewing_with_no_status_line_involved
    # The anchor stays alive for five checks, then dies. Nothing in this test paints
    # a status line — that is the point: renewal is a property of the RUN.
    result = run_loop(alive: [true, true, true, true, true, false])
    assert_equal :anchor_gone, result[:outcome]
    assert_equal 5, result[:renews],
                 "a headless holder must renew on its own cadence, not when a UI happens to paint"
  end

  def test_unit_the_renew_cadence_comfortably_outruns_the_lease_ttl
    # The whole guarantee rests on this inequality, so assert it rather than trusting
    # two constants in two files to stay in step. A renewer that slept LONGER than the
    # TTL would let the lane go free mid-work — the original bug, reintroduced.
    assert_operator ShiftRenewer::INTERVAL_SECONDS, :<, ClaimLease::DEFAULT_TTL_SECONDS
    assert_operator ShiftRenewer::INTERVAL_SECONDS * 2, :<=, ClaimLease::DEFAULT_TTL_SECONDS,
                    "at least two renewals must fit inside one TTL, so a single missed beat is survivable"
  end

  # --- the other half: a genuinely dead holder must NOT wedge the lane -----------

  def test_unit_a_dead_anchor_stops_the_renewer_immediately
    result = run_loop(alive: [false])
    assert_equal :anchor_gone, result[:outcome]
    assert_equal 0, result[:renews], "a dead holder renews nothing, so its lease lapses within the TTL"
    assert_empty result[:slept]
  end

  def test_unit_losing_the_lease_stops_the_renewer_rather_than_spinning
    # The board said "you no longer hold this" (a clean release elsewhere, or the lane
    # changed hands). Keep looping and we would fight the new holder forever.
    result = run_loop(alive: [], renew: [true, true, false])
    assert_equal :lease_lost, result[:outcome]
    assert_equal 3, result[:renews]
  end

  def test_unit_a_safety_cap_bounds_a_renewer_whose_anchor_check_never_fails
    # Belt and braces: if liveness probing were ever wrong, the renewer still cannot
    # hold a lane forever. Prefer a lapsed lease over an immortal phantom holder.
    result = run_loop(alive: [], interval: 30, max_lifetime: 90)
    assert_equal :max_lifetime, result[:outcome]
    assert_equal 3, result[:renews], "renews at t=0, 30, 60 then stops at the 90s cap"
  end

  # --- the interval is tunable for tests, but never into the danger zone ----------

  def test_unit_a_configured_interval_is_clamped_below_the_ttl
    assert_equal 1, ShiftRenewer.interval_from("0"), "a zero/negative interval would busy-spin"
    assert_equal 5, ShiftRenewer.interval_from("5")
    assert_equal ShiftRenewer::MAX_INTERVAL_SECONDS, ShiftRenewer.interval_from("99999"),
                 "an over-long interval must be clamped — it would let the lease lapse mid-work"
    assert_equal ShiftRenewer::INTERVAL_SECONDS, ShiftRenewer.interval_from(nil)
    assert_equal ShiftRenewer::INTERVAL_SECONDS, ShiftRenewer.interval_from("not-a-number")
  end
end
