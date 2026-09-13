# frozen_string_literal: true

# [unit] tests for bin/lib/build_claim_renewer.rb — the CONTROL half of the detached
# build-claim renewer. The I/O half (one renewal attempt) lives in bin/task
# #renew_build_claim; the end-to-end proof that a real detached process really renews
# and really stops lives in test/commands/build_claim_renewer_integration_test.rb.
#
# THE BUG THIS FILE EXISTS FOR (verified at source by two sessions, 2026-09-09): the
# build claim was renewed ONLY by bin/statusline, so renewal was a property of the UI
# rather than of the run. A HEADLESS AGENT SHELL PAINTS NOTHING, so a headless build
# renewed nothing and its 120s lease lapsed for the rest of the build — while a cold
# `bin/ship` runs ~12 minutes BY DESIGN. Two agents could then legitimately hold one
# task, and neither was doing anything wrong.
#
# WHAT THESE TESTS PIN is the asymmetry that makes the fix safe, and it is the whole
# design in three rules:
#
#   * A DEAD BUILDER LOSES THE CLAIM. The anchor is the only signal that resolves
#     toward stopping, because a lease that outlives a dead holder strands a task
#     nobody can pick up — worse than one that lapses too fast.
#   * FINISHED WORK ENDS THE LOOP, so a session that builds many tasks does not
#     accumulate one immortal renewer per task (the review lane's 2026-08-30 scar).
#   * EVERYTHING ELSE KEEPS BEATING. A declined beat and an unreachable board are not
#     evidence the builder is gone. Stopping on either would drop a LIVE build's lease
#     and remove the desk-backed recovery path that re-adopts it.
#
#   ruby -Itest test/lib/build_claim_renewer_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/build_claim_renewer"
require_relative "../../bin/lib/shift_renewer"
require_relative "../../lib/claim_lease"

class BuildClaimRenewerTest < Minitest::Test
  # A scripted run BOUNDED BY A GUARD, for the reason test/lib/shift_renewer_test.rb
  # states: several tests below script NO stop at all, because the outcome under test
  # is supposed to be the thing that ends the loop. Without the guard a regression
  # HANGS — a worse signal than a failure, since it stalls the suite and names nothing.
  # With it, a regression falls out as :anchor_gone and every assertion reports itself.
  GUARD_CYCLES = 25

  # Drive the loop over a scripted sequence of beat outcomes. `beats` is consumed in
  # order and then repeats its last entry forever, so "keeps beating" is expressible.
  def run_loop(beats, alive: [], interval: 30, unreachable_grace: BuildClaimRenewer::UNREACHABLE_GRACE_SECONDS)
    seen = []
    cycles = 0
    script = beats.dup
    outcome = BuildClaimRenewer.run(
      alive: -> { (cycles += 1) > GUARD_CYCLES ? false : (alive.empty? ? true : alive.shift) },
      beat: -> { (script.length > 1 ? script.shift : script.first).tap { |o| seen << o } },
      sleeper: ->(_seconds) { @slept = (@slept || 0) + 1 },
      clock: -> { @now = (@now || Time.utc(2026, 9, 9, 4, 0, 0)) + 1 },
      interval: interval,
      max_lifetime: 3_600,
      unreachable_grace: unreachable_grace
    )
    [outcome, seen]
  end

  # ── A DEAD BUILDER LOSES THE CLAIM ──────────────────────────────────────────

  def test_a_dead_anchor_stops_the_loop_at_once
    outcome, seen = run_loop([:renewed], alive: [false])

    assert_equal :anchor_gone, outcome,
                 "the anchor is the one signal that resolves toward STOPPING: a lease that " \
                 "outlives a dead builder strands a task no sweep can distinguish from live work"
    assert_empty seen, "and it must stop BEFORE renewing — a dead builder is owed no heartbeat"
  end

  def test_a_builder_that_dies_mid_build_stops_being_renewed
    outcome, seen = run_loop(%i[renewed renewed renewed], alive: [true, true, false])

    assert_equal :anchor_gone, outcome
    assert_equal %i[renewed renewed], seen,
                 "renewal stops the moment the anchor does; the ordinary #{ClaimLease::DEFAULT_TTL_SECONDS}s " \
                 "TTL then frees the task, which is why that number stays where it is"
  end

  # ── FINISHED WORK ENDS THE LOOP ─────────────────────────────────────────────

  def test_a_task_that_has_left_building_ends_the_loop
    outcome, seen = run_loop(%i[renewed not_building])

    assert_equal :work_finished, outcome,
                 "a build claim on a task that is no longer building protects nothing"
    assert_equal %i[renewed not_building], seen,
                 "and it asks the board NOTHING further — the poll that never happens is what " \
                 "keeps one renewer per task from becoming an immortal one"
  end

  def test_work_already_finished_when_the_loop_starts_renews_nothing_further
    outcome, seen = run_loop([:not_building])

    assert_equal :work_finished, outcome
    assert_equal 1, seen.length,
                 "the single beat that learned the stage is the only board traffic a renewer " \
                 "born obsolete may produce"
  end

  # ── A LIVE FOREIGN HOLDER ENDS THE LOOP ─────────────────────────────────────

  def test_a_different_live_instance_taking_the_claim_ends_the_loop
    outcome, seen = run_loop(%i[renewed held_by_other])

    assert_equal :lease_lost, outcome,
                 "every consumer REFUSES on :held_by_other; a renewer that kept posting into " \
                 "someone else's claim would be writing nothing and reporting success"
    assert_equal %i[renewed held_by_other], seen
  end

  # ── EVERYTHING ELSE KEEPS BEATING ───────────────────────────────────────────

  def test_a_declined_beat_does_not_end_the_loop
    # Declining is HOW the abandonment guard works, and it is self-healing: the lease
    # lapses, and when the desk goes warm again the next beat re-adopts it from the
    # task's BOUND desk. A loop that exited here would remove that recovery path and
    # leave a working builder permanently unclaimed.
    outcome, seen = run_loop([:declined])

    assert_equal :anchor_gone, outcome, "only the GUARD ended this loop — nothing in the design did"
    assert_equal GUARD_CYCLES, seen.length, "a declined beat is not a stop condition"
  end

  def test_an_unreachable_board_does_not_end_the_loop
    # A board we could not read has told us nothing about the builder. Stopping on a
    # network blip would drop a LIVE build's lease and hand the task to the next
    # session — the collision this whole mechanism exists to prevent.
    outcome, seen = run_loop([:cant_run])

    assert_equal :anchor_gone, outcome
    assert_equal GUARD_CYCLES, seen.length, "an uncertainty must never free a claim"
  end

  # ── ...BUT NOT FOREVER, AND ONLY WHILE THE SILENCE IS UNBROKEN ──────────────

  def test_a_permanently_unreachable_board_eventually_ends_the_loop
    # An uncertainty keeps beating; an uncertainty that never resolves must not become
    # a process polling a dead endpoint until its anchor dies. This feature's own first
    # cut left two of those running on the machine that wrote it.
    outcome, seen = run_loop([:cant_run], interval: 30, unreachable_grace: 120)

    assert_equal :board_unreachable, outcome,
                 "and it says WHY in its own words — 'we could not ask' is not 'we were told no', " \
                 "and a reader debugging a vanished claim needs those two apart"
    assert_equal 4, seen.length,
                 "four beats at 30s exhausts a 120s grace; past one TTL of failed renewals there " \
                 "is no lease left to protect, so everything after that is recovery"
  end

  def test_an_intermittent_board_never_exhausts_the_grace
    # THE ASSERTION THAT SEPARATES "consecutive" FROM "total". A flapping connection
    # answers sometimes; a board that replies at all has not been unreachable for the
    # window, and a renewer that counted total failures would drop a live builder's
    # claim on a bad afternoon.
    outcome, seen = run_loop(%i[cant_run cant_run renewed cant_run cant_run renewed],
                             interval: 30, unreachable_grace: 120)

    assert_equal :anchor_gone, outcome, "only the GUARD ended this loop — the grace never ran out"
    assert_equal GUARD_CYCLES, seen.length
  end

  def test_a_holder_that_recovers_after_declining_is_renewed_again
    outcome, seen = run_loop(%i[declined declined renewed not_building])

    assert_equal :work_finished, outcome
    assert_equal %i[declined declined renewed not_building], seen,
                 "the desk went warm again and the lease was re-adopted; that recovery is only " \
                 "reachable because a decline kept the loop alive"
  end

  # ── THE SAFETY CAP ──────────────────────────────────────────────────────────

  def test_the_lifetime_cap_bounds_a_loop_nothing_else_stops
    now = Time.utc(2026, 9, 9, 4, 0, 0)
    outcome = BuildClaimRenewer.run(
      alive: -> { true },
      beat: -> { :renewed },
      sleeper: ->(_seconds) { nil },
      clock: -> { now += 600 },
      interval: 30,
      max_lifetime: 3_600
    )

    assert_equal :max_lifetime, outcome,
                 "if liveness probing were ever wrong, a renewer must still not hold a claim " \
                 "forever — the cap is the belt-and-braces bound, not the design"
  end

  # ── A RENEWER THAT CANNOT SEE ITS BUILDER IS BOUNDED ────────────────────────
  #
  # With no desk, the abandonment check answers "unknown", and unknown never frees a
  # claim — so a desk-less renewer used to run the full 12h cap on a builder it could
  # not see. It is now bounded by the house's own derived quiet ceiling.
  def test_a_renewer_with_no_desk_is_bounded_below_the_lifetime_cap
    assert_equal ShiftRenewer::MAX_LIFETIME_SECONDS, BuildClaimRenewer.lifetime_for(desk: "/a/bound/desk"),
                 "a desk can vouch for the holder, so the ordinary cap applies"
    bound = BuildClaimRenewer.lifetime_for(desk: nil)
    assert_operator bound, :<, ShiftRenewer::MAX_LIFETIME_SECONDS, "no desk must mean a SHORTER leash"
    assert_equal ClaimLease::PROGRESS_QUIET_SECONDS, bound,
                 "derived from the measured quiet ceiling, not typed next to it"
    assert_equal bound, BuildClaimRenewer.lifetime_for(desk: "  "), "a blank desk is no desk"
  end

  def test_the_loop_is_wired_to_the_desk_aware_lifetime
    # A bound that no caller passes is decoration. The detached loop is started with
    # `--desk` only when one resolved, so the loop must choose its cap from that.
    source = File.read(File.expand_path("../../bin/task", __dir__))
    loop_body = source[/when "claim-renew-loop".*?BuildClaimRenewer\.run\((.*?)\n  \)/m, 1].to_s
    refute_empty loop_body, "could not find the claim-renew-loop's BuildClaimRenewer.run call"
    assert_match(/max_lifetime:\s*BuildClaimRenewer\.lifetime_for\(desk: renew_desk\)/, loop_body)
  end

  # ── THE MAPPING ITSELF, so the two predicates cannot silently swap ──────────

  def test_only_a_live_foreign_holder_stops_the_beat
    stops = BuildClaimRenewer::OUTCOMES.reject { |o| BuildClaimRenewer.continue?(o) }

    assert_equal [:held_by_other], stops,
                 "widening this set is how an uncertainty starts freeing live builders' claims"
  end

  def test_only_a_task_off_building_counts_as_finished
    finished = BuildClaimRenewer::OUTCOMES.select { |o| BuildClaimRenewer.finished?(o) }

    assert_equal [:not_building], finished
  end

  def test_the_production_beat_is_derived_from_the_shared_ttl
    # The guarantee rests on INTERVAL < TTL, and the margin is what makes a single
    # missed beat survivable. Re-typing the number next to the TTL is how the two drift.
    assert_equal ClaimLease::DEFAULT_TTL_SECONDS / 4, ShiftRenewer::INTERVAL_SECONDS
    assert_operator ShiftRenewer::INTERVAL_SECONDS, :<, ClaimLease::DEFAULT_TTL_SECONDS
  end
end
