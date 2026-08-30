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
  # A scripted run BOUNDED BY A GUARD: `alive` answers from a queue and then defaults
  # to true, every renew succeeds unless the renew queue says otherwise, and sleeping
  # only advances a fake clock.
  #
  # THE GUARD IS NOT DECORATION. Several tests below deliberately script NO stop at
  # all in `alive` or `renew`, because the condition under test is supposed to be the
  # thing that ends the loop. Remove that condition and the loop runs forever — and a
  # test that HANGS on a regression is a much worse signal than one that fails: it
  # stalls CI for its whole timeout and names nothing. With the guard, a regression
  # falls out as `:anchor_gone` after GUARD_CYCLES and every assertion below reports
  # the defect by name.
  GUARD_CYCLES = 50

  def run_loop(alive:, renew: [], finished: [], interval: 30, max_lifetime: 3600)
    slept = []
    now = Time.utc(2026, 7, 20, 12, 0, 0)
    renews = 0
    cycles = 0
    outcome = ShiftRenewer.run(
      alive: -> { (cycles += 1) > GUARD_CYCLES ? false : (alive.empty? ? true : alive.shift) },
      finished: -> { finished.empty? ? false : finished.shift },
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

  # --- the third stop condition: the WORK is done, though the holder is not -------
  #
  # These four are the 2026-08-30 regression. Note what every one of them holds
  # FIXED: `alive` is never scripted to go false and `renew` is never scripted to
  # fail, so the two pre-existing exits are unreachable throughout. Any of these
  # tests passing against the old two-exit loop would be a test that proved nothing —
  # which is precisely the trap this defect hid in for two days.

  def test_unit_a_renewer_stops_when_its_work_finishes_though_its_anchor_lives_on
    # The outage in one assertion. The anchor never dies (a real session, still
    # legitimately working) and the board never revokes the lease (the claim is still
    # genuinely held) — and yet there is nothing left to protect, because the task
    # shipped. Before this exit existed, this loop ran until the machine rebooted.
    result = run_loop(alive: [], renew: [], finished: [false, true])

    assert_equal :work_finished, result[:outcome]
    # ORDER, pinned by arithmetic. `finished` says "not yet" once, then "done".
    # Checked BEFORE the renew that is ONE renew; checked after it, it would be TWO —
    # and that second one is the bug in miniature: a poll spent to learn a fact that
    # was already true. This number is the whole acceptance criterion.
    assert_equal 1, result[:renews],
                 "the completion check must run BEFORE the renew, or every finished loop " \
                 "still pays for one last pointless heartbeat"
    assert_equal [30], result[:slept]
  end

  def test_unit_a_renewer_born_after_its_work_finished_never_polls_at_all
    # The five loops found running on 2026-08-30 were each spawned while their task
    # was live, but a renewer restarted (or spawned late) against already-finished
    # work must not get one free heartbeat either.
    result = run_loop(alive: [], renew: [], finished: [true])

    assert_equal :work_finished, result[:outcome]
    assert_equal 0, result[:renews], "there was never anything to renew"
    assert_empty result[:slept], "and nothing to wait for"
  end

  def test_unit_unfinished_work_never_interrupts_a_live_lease
    # The other direction, and the one with teeth: a completion check that fired
    # eagerly would drop a LIVE reviewer's lease and let a second session claim the
    # task underneath them — the very collision this file exists to prevent.
    result = run_loop(alive: [true, true, true, false], renew: [], finished: [false, false, false])

    assert_equal :anchor_gone, result[:outcome]
    assert_equal 3, result[:renews], "work that is not finished is renewed, every cycle, as before"
  end

  def test_unit_a_lease_with_no_completion_signal_behaves_exactly_as_it_always_did
    # bin/devops-shift holds a ROLE lease on a LANE, not on a unit of work, so it has
    # no completion signal to give and passes none. Called without `finished:`, the
    # loop must be byte-for-byte the old two-exit loop — this pins the default so the
    # review-claim fix cannot quietly change the shift lease's behavior.
    renews = 0
    alive = [true, true, false]
    outcome = ShiftRenewer.run(
      alive: -> { alive.shift },
      renew: -> { renews += 1; true },
      sleeper: ->(_s) { nil },
      clock: -> { Time.utc(2026, 7, 20, 12, 0, 0) }
    )

    assert_equal :anchor_gone, outcome
    assert_equal 2, renews
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
