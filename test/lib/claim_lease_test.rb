# frozen_string_literal: true

# Unit tests for the build-stage claim lease math (lib/claim_lease.rb). Pure
# functions — the clock and both instance identities are injected, so nothing
# shells out or reads the process tree. This is the unit tier for all four
# acceptance criteria; the bin/task gate + bin/statusline heartbeat get exercised
# end-to-end at the integration tier (test/lib/task_cli_test.rb, statusline_test.rb).
#
#   ruby -Itest test/lib/claim_lease_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "time"
require_relative "../../lib/claim_lease"

class ClaimLeaseTest < Minitest::Test
  NOW = Time.utc(2026, 6, 23, 12, 0, 0)
  SESSION = "3751cb0d-9e1d-4260-ab96-20f5b00c0547"
  OTHER_SESSION = "aaaa1111-bbbb-2222-cccc-333344445555"

  def claim(session: SESSION, nonce: "inst-A", expires: NOW + 90)
    {
      "claimed_session"  => session,
      "claim_nonce"      => nonce,
      "claim_expires_at" => expires.is_a?(Time) ? expires.utc.iso8601 : expires
    }
  end

  # --- AC #1: building a claimed task warns UNLESS the lease has expired --------

  def test_live_claim_by_another_instance_is_held_by_other
    decision = ClaimLease.evaluate(claim(nonce: "inst-A"), session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :held_by_other, decision, "a live claim by a different instance must warn the mover"
  end

  def test_expired_claim_does_not_warn
    decision = ClaimLease.evaluate(claim(nonce: "inst-A", expires: NOW - 1), session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :expired, decision, "an expired lease is reclaimable — no warning"
  end

  # --- AC #2: the claim is keyed on session id PLUS a process nonce -------------

  def test_same_session_same_nonce_is_the_same_instance
    decision = ClaimLease.evaluate(claim(nonce: "inst-A"), session: SESSION, nonce: "inst-A", now: NOW)
    assert_equal :same_instance, decision, "session + nonce both match → this very instance re-moving"
  end

  def test_same_session_different_nonce_is_a_different_instance
    decision = ClaimLease.evaluate(claim(nonce: "inst-A"), session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :held_by_other, decision, "same session id, different nonce → a different live instance"
  end

  def test_different_session_is_a_different_instance
    decision = ClaimLease.evaluate(claim(session: OTHER_SESSION), session: SESSION, nonce: "inst-A", now: NOW)
    assert_equal :held_by_other, decision, "a different session holding a live claim must warn"
  end

  # --- AC #3: an expired OR dead-session lease is reclaimable automatically -----

  def test_unclaimed_is_reclaimable
    assert_equal :unclaimed, ClaimLease.evaluate({}, session: SESSION, nonce: "inst-A", now: NOW)
    assert_equal :unclaimed, ClaimLease.evaluate({ "claimed_session" => "" }, session: SESSION, nonce: "x", now: NOW)
  end

  def test_lease_past_expiry_is_reclaimable
    decision = ClaimLease.evaluate(claim(expires: NOW - 30), session: OTHER_SESSION, nonce: "inst-Z", now: NOW)
    assert_equal :expired, decision
  end

  def test_lease_with_no_expiry_fails_open_to_reclaimable
    # A dead session stops renewing → its lease lapses; a claim that carries NO
    # expiry at all (never renewed / pre-lease era) must free the task, never
    # lock it forever. Note the contrast with a GARBLED expiry, which is
    # :corrupt — see the corrupt-expiry section below.
    assert_equal :expired, ClaimLease.evaluate(claim(expires: nil), session: OTHER_SESSION, nonce: "z", now: NOW)
    assert_equal :expired, ClaimLease.evaluate(claim(expires: ""), session: OTHER_SESSION, nonce: "z", now: NOW)
  end

  # --- Corrupt expiry: unverifiable is NOT lapsed --------------------------------
  # A claim whose expiry is PRESENT but unparseable is "we could not check", not
  # "the builder is gone". The reclaim guard (bin/agent-worktree claim_hold)
  # decides destruction off live?, so a corrupt lease must read as possibly
  # live — withheld — never as free. bin/task's build gate keeps its fail-open
  # posture because it branches only on :held_by_other (and claiming WRITES a
  # fresh lease, healing the corruption; destroying a desk heals nothing).

  def test_corrupt_expiry_evaluates_as_corrupt_not_expired
    decision = ClaimLease.evaluate(claim(expires: "not-a-time"), session: OTHER_SESSION, nonce: "z", now: NOW)
    assert_equal :corrupt, decision, "a garbled lease is unverifiable, not lapsed"
  end

  def test_corrupt_expiry_is_corrupt_even_for_the_holding_instance
    # The lease disposition outranks identity (mirroring :expired): the gate
    # still passes (:corrupt != :held_by_other) and the re-claim writes a fresh
    # parseable lease, so the holder heals its own corrupted record.
    decision = ClaimLease.evaluate(claim(nonce: "inst-A", expires: "not-a-time"), session: SESSION, nonce: "inst-A", now: NOW)
    assert_equal :corrupt, decision
  end

  def test_corrupt_expiry_reads_as_possibly_live
    assert ClaimLease.live?(claim(expires: "not-a-time"), now: NOW),
           "an unverifiable lease must read as possibly live — the reclaim guard withholds on live?"
    refute ClaimLease.live?(claim(expires: nil), now: NOW), "a BLANK expiry stays fail-open (lapsed)"
  end

  def test_corrupt_expiry_without_a_session_is_still_unclaimed
    orphan = { "claim_expires_at" => "not-a-time" }
    assert_equal :unclaimed, ClaimLease.evaluate(orphan, session: SESSION, nonce: "z", now: NOW)
    refute ClaimLease.live?(orphan, now: NOW), "no holder → nothing to protect"
    refute ClaimLease.corrupt_expiry?(orphan)
  end

  def test_corrupt_expiry_predicate
    assert ClaimLease.corrupt_expiry?(claim(expires: "not-a-time"))
    refute ClaimLease.corrupt_expiry?(claim(expires: NOW + 30)), "a parseable lease is not corrupt"
    refute ClaimLease.corrupt_expiry?(claim(expires: nil)), "a blank expiry is absent, not corrupt"
    refute ClaimLease.corrupt_expiry?({}), "no claim at all"
    refute ClaimLease.corrupt_expiry?(nil)
  end

  def test_corrupt_expiry_has_no_heartbeat_age
    assert_nil ClaimLease.heartbeat_age(claim(expires: "not-a-time"), now: NOW),
               "an unparseable lease yields no age — consumers must tolerate nil"
  end

  def test_lease_exactly_at_now_is_expired
    decision = ClaimLease.evaluate(claim(expires: NOW), session: OTHER_SESSION, nonce: "z", now: NOW)
    assert_equal :expired, decision, "expiry boundary is inclusive — at-now counts as lapsed"
  end

  # --- AC #4: one session open in two terminals is DETECTED ---------------------

  def test_same_session_two_terminals_is_detected_as_distinct_live_instances
    # Terminal A claimed with nonce inst-A (its process). Terminal B is a
    # `claude --resume` of the SAME session id but a NEW process → nonce inst-B.
    # B asking to build must be detected as a second live instance, not waved through.
    held = claim(session: SESSION, nonce: "inst-A", expires: NOW + 60)
    decision = ClaimLease.evaluate(held, session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :held_by_other, decision
    refute_equal :same_instance, decision, "two terminals of one session must NOT look like the same instance"
  end

  # --- Graceful degrade: no nonce determinable on either side ------------------

  def test_session_only_claim_degrades_to_same_instance_for_the_same_session
    # When the nonce can't be resolved (empty on both sides), the claim degrades
    # to session-level: the same session is treated as the same instance (still
    # catches a DIFFERENT session), rather than locking the holder out of itself.
    held = claim(session: SESSION, nonce: "", expires: NOW + 60)
    assert_equal :same_instance, ClaimLease.evaluate(held, session: SESSION, nonce: "", now: NOW)
    assert_equal :held_by_other, ClaimLease.evaluate(held, session: OTHER_SESSION, nonce: "", now: NOW)
  end

  # --- ship-claim-blank-nonce: absence of a nonce is NOT a different instance ---
  # A BLANK nonce on EITHER side means "instance unknown" (the SessionIdentity
  # degrade contract), so a same-session claim still reads as the SAME instance.
  # The live failure: a detached status-line heartbeat renewal blanked the STORED
  # nonce, then the true owner's populated CURRENT nonce was compared against blank
  # and the owner was locked out of its OWN task. Assert the POSITIVE invariant
  # across the whole nonce-visibility matrix, not one spelling: two DISTINCT live
  # instances are refused ONLY when BOTH nonces are known and differ; every case
  # with a blank on either side degrades to session-level.
  def test_same_session_blank_nonce_on_either_side_is_the_same_instance
    good = "inst-A"
    { # [stored_nonce, current_nonce] => expected disposition, same session
      ["", good]       => :same_instance,  # the live bug: blank stored, populated current
      [good, ""]       => :same_instance,  # current process can't resolve a nonce (degrade)
      ["", ""]         => :same_instance,  # neither side knows (matrix completeness)
      [good, good]     => :same_instance,  # the very same instance re-asking
      [good, "inst-B"] => :held_by_other   # BOTH known and differ → two real terminals
    }.each do |(stored, current), expected|
      decision = ClaimLease.evaluate(claim(nonce: stored), session: SESSION, nonce: current, now: NOW)
      assert_equal expected, decision,
                   "same session, stored=#{stored.inspect}, current=#{current.inspect} must be #{expected}"
    end
  end

  def test_blank_stored_nonce_still_refuses_a_different_session
    # The fix must not over-open: a blank stored nonce degrades to SESSION level,
    # which still refuses a genuinely different session (the original duplicate-
    # work guard). Absence lowers the resolution; it never disables the gate.
    decision = ClaimLease.evaluate(claim(session: SESSION, nonce: ""), session: OTHER_SESSION, nonce: "inst-B", now: NOW)
    assert_equal :held_by_other, decision, "a different session is refused even when the stored nonce is blank"
  end

  # --- ship-claim-blank-nonce: renewal must never DOWNGRADE a good nonce -------
  # The second half of the fix. Once evaluate treats blank as same-instance, the
  # detached blank-nonce heartbeat no longer SKIPS — it renews. If that renewal
  # wrote the blank through, it would erase the per-instance token on every render
  # and permanently weaken the two-terminals guard. A renewal whose fresh nonce is
  # blank must keep the SAME session's prior nonce.
  def test_renewed_preserves_a_good_nonce_when_the_fresh_one_is_blank
    prior = claim(session: SESSION, nonce: "inst-A", expires: NOW + 30)
    fresh = ClaimLease.renewed(session: SESSION, nonce: "", now: NOW, ttl: 120, prior: prior)
    assert_equal "inst-A", fresh["claim_nonce"], "a blank renewal must not erase the stored nonce"
    assert_equal (NOW + 120).utc.iso8601, fresh["claim_expires_at"], "the lease is still freshly extended"
    # The preserved nonce keeps the two-terminals guard alive for the task.
    assert_equal :held_by_other, ClaimLease.evaluate(fresh, session: SESSION, nonce: "inst-B", now: NOW)
  end

  def test_renewed_never_inherits_a_different_sessions_nonce
    prior = claim(session: OTHER_SESSION, nonce: "inst-A", expires: NOW + 30)
    fresh = ClaimLease.renewed(session: SESSION, nonce: "", now: NOW, ttl: 120, prior: prior)
    assert_equal "", fresh["claim_nonce"], "a different session's nonce must never be inherited"
    assert_equal SESSION, fresh["claimed_session"]
  end

  def test_renewed_prefers_a_freshly_resolved_nonce_over_the_prior
    # A later render that DOES resolve a nonce re-populates a blanked claim — this
    # is how the blank self-heals. A resolved nonce always wins over the prior.
    prior = claim(session: SESSION, nonce: "", expires: NOW + 30)
    fresh = ClaimLease.renewed(session: SESSION, nonce: "inst-A", now: NOW, ttl: 120, prior: prior)
    assert_equal "inst-A", fresh["claim_nonce"], "a freshly resolved nonce heals a previously blank claim"
  end

  # --- live? + heartbeat_age + renewed -----------------------------------------

  def test_live_predicate
    assert ClaimLease.live?(claim(expires: NOW + 30), now: NOW)
    refute ClaimLease.live?(claim(expires: NOW - 30), now: NOW)
    refute ClaimLease.live?({}, now: NOW)
  end

  def test_heartbeat_age_is_derived_from_expiry_and_ttl
    # expiry = last_heartbeat + TTL ⇒ age = TTL - (expiry - now).
    age = ClaimLease.heartbeat_age(claim(expires: NOW + 90), now: NOW, ttl: 120)
    assert_equal 30, age, "120s TTL, lease has 90s left ⇒ last heartbeat 30s ago"
    assert_equal 0, ClaimLease.heartbeat_age(claim(expires: NOW + 200), now: NOW, ttl: 120), "never negative"
    assert_nil ClaimLease.heartbeat_age({}, now: NOW)
  end

  def test_renewed_writes_identity_and_a_fresh_lease
    fresh = ClaimLease.renewed(session: SESSION, nonce: "inst-A", now: NOW, ttl: 120)
    assert_equal SESSION, fresh["claimed_session"]
    assert_equal "inst-A", fresh["claim_nonce"]
    assert_equal (NOW + 120).utc.iso8601, fresh["claim_expires_at"]
    # A just-renewed claim reads back as this same live instance.
    assert_equal :same_instance, ClaimLease.evaluate(fresh, session: SESSION, nonce: "inst-A", now: NOW)
  end

  def test_from_devops_extracts_only_claim_keys
    devops = { "kind" => "feature", "claimed_session" => SESSION, "claim_nonce" => "n", "claim_expires_at" => "t" }
    assert_equal({ "claimed_session" => SESSION, "claim_nonce" => "n", "claim_expires_at" => "t" },
                 ClaimLease.from_devops(devops))
  end

  # --- Progress, which is NOT liveness ---------------------------------------

  def live_claim
    ClaimLease.renewed(session: SESSION, nonce: "inst-A", now: NOW)
  end

  def test_progress_age_measures_from_the_last_durable_artifact
    assert_equal 1800, ClaimLease.progress_age(NOW - 1800, now: NOW)
    assert_equal 1800, ClaimLease.progress_age((NOW - 1800).iso8601, now: NOW)
  end

  def test_progress_age_is_unknown_without_an_artifact_and_never_negative
    assert_nil ClaimLease.progress_age(nil, now: NOW)
    assert_nil ClaimLease.progress_age("", now: NOW)
    assert_nil ClaimLease.progress_age("not-a-time", now: NOW)
    assert_equal 0, ClaimLease.progress_age(NOW + 30, now: NOW)
  end

  # The regression this feature exists for: a lease that keeps heartbeating while
  # the agent produces nothing is LIVE but QUIET — the board may no longer read
  # that green dot as progress. Silence stated RELATIVE TO THE THRESHOLD, not as a
  # literal: this asserts "past the bar", whatever the bar is derived to be.
  def test_a_live_lease_with_no_durable_write_reads_quiet
    silence = ClaimLease::PROGRESS_QUIET_SECONDS + 600

    assert ClaimLease.quiet?(live_claim, last_progress_at: NOW - silence, now: NOW)
  end

  # ...and the other half of the same regression: a lease whose task IS landing
  # durable writes (a cert checkpoint, a gate lane) is never quiet.
  def test_a_lease_making_durable_writes_is_not_quiet
    refute ClaimLease.quiet?(live_claim, last_progress_at: NOW - 60, now: NOW)
  end

  # THE 8-MINUTE-CERT CASE — the trap this design must not fall into. A healthy
  # `bin/fast-check` across ~120 mapped test files makes zero board writes for
  # minutes on end. Silence is not a wedge: an in-flight gate suppresses the call
  # outright, AND the threshold clears the measured cert p99 on its own, so a cert
  # whose gate row never landed still keeps its desk.
  def test_a_long_running_cert_is_never_quiet
    cert_p99 = ClaimLease::MEASURED_SILENCE_SECONDS.fetch(:cert_p99)

    refute ClaimLease.quiet?(live_claim, last_progress_at: NOW - cert_p99, in_flight: true, now: NOW)
    refute ClaimLease.quiet?(live_claim, last_progress_at: NOW - cert_p99, now: NOW)
  end

  def test_an_in_flight_gate_always_suppresses_quiet
    refute ClaimLease.quiet?(live_claim, last_progress_at: NOW - 100_000, in_flight: true, now: NOW)
  end

  # Fail safe: an unknown progress fact is NOT trouble. A false "stalled" chip on
  # a healthy desk is the frequent lying-RED this design refuses to trade for.
  def test_unknown_progress_reads_healthy_never_quiet
    refute ClaimLease.quiet?(live_claim, last_progress_at: nil, now: NOW)
    refute ClaimLease.quiet?(live_claim, last_progress_at: "garbled", now: NOW)
  end

  # Quiet is a statement about a HELD desk. Nothing to say about an empty one.
  def test_an_unclaimed_or_expired_lease_is_never_quiet
    refute ClaimLease.quiet?({}, last_progress_at: NOW - 100_000, now: NOW)
    expired = ClaimLease.renewed(session: SESSION, nonce: "inst-A", now: NOW - 9000)
    refute ClaimLease.quiet?(expired, last_progress_at: NOW - 100_000, now: NOW)
  end

  # --- The threshold, asserted as a PROPERTY -------------------------------
  #
  # The previous cut of this file pinned the LITERAL — `assert_equal 7200,
  # PROGRESS_QUIET_SECONDS` — and so it certified, green, a threshold sitting five
  # minutes BELOW the p99 its own comment claimed to clear. A test that pins the
  # spelling cannot see a constant drift under its evidence; only a test that
  # asserts the INVARIANT can. The invariant: no measured HEALTHY window may ever
  # render quiet. Drift the constant beneath the corpus and these go red, whatever
  # number it drifts to.
  def test_no_measured_healthy_window_ever_reads_quiet
    ClaimLease::MEASURED_SILENCE_SECONDS.each do |percentile, silence|
      refute ClaimLease.quiet?(live_claim, last_progress_at: NOW - silence, now: NOW),
             "#{percentile} (#{silence}s) is MEASURED HEALTHY work, but the quiet threshold " \
             "(#{ClaimLease::PROGRESS_QUIET_SECONDS}s) flags it — the chip would cry wolf on " \
             "healthy desks, the exact failure this feature exists to prevent"
    end
  end

  # The same invariant stated against the constant itself, so a REVIEWER reading the
  # threshold sees the rule it must obey: clear the worst measured window, and clear
  # it by the stated margin (the p99 at n=243 rests on ~2 tail observations, so the
  # threshold may not sit ON the estimate).
  def test_the_threshold_clears_the_worst_measured_window_by_its_stated_margin
    worst = ClaimLease::MEASURED_SILENCE_SECONDS.values.max

    assert_operator ClaimLease::PROGRESS_QUIET_SECONDS, :>, worst,
                    "the threshold must exceed the measured healthy-silence p99 it claims to clear"
    assert_operator ClaimLease::PROGRESS_QUIET_SECONDS, :>=, worst * ClaimLease::QUIET_SAFETY_FACTOR,
                    "the threshold must honour the safety factor its own comment derives it from"
  end

  # ...and the threshold must still BITE, or "clear the p99" is satisfied by making
  # it enormous and the chip never fires at all. The bound is stated against the
  # evidence too: a desk silent for THREE TIMES the worst healthy window ever
  # measured has left the healthy distribution behind, and must be flagged.
  def test_a_silence_far_past_every_measured_window_reads_quiet
    beyond = ClaimLease::MEASURED_SILENCE_SECONDS.values.max * 3

    assert ClaimLease.quiet?(live_claim, last_progress_at: NOW - beyond, now: NOW),
           "a threshold that cannot flag 3x the worst measured healthy window is inert"
  end

  def test_the_quiet_threshold_is_tunable_per_call
    assert ClaimLease.quiet?(live_claim, last_progress_at: NOW - 1200, quiet_after: 600, now: NOW)
  end

  # One formatter for the age, shared by the board card and the claim gate bin/task
  # prints — two renderings of one fact could word it differently. Asserted against
  # fixed inputs, NOT against PROGRESS_QUIET_SECONDS: the formatter's contract has
  # nothing to do with the threshold, and coupling it there would make a re-derived
  # threshold break a test about string formatting.
  def test_humanize_age_renders_seconds_minutes_and_hours
    assert_equal "42s", ClaimLease.humanize_age(42)
    assert_equal "28m", ClaimLease.humanize_age(28 * 60)
    assert_equal "2.1h", ClaimLease.humanize_age(7_500)
  end

  # --- Abandonment: the one predicate that can cost a holder its desk --------
  #
  # `quiet?` above only reports. THESE decide, so they are written as the two
  # errors the predicate can make, and they are not symmetric: freeing a desk too
  # late costs waiting, freeing it too early costs the work.

  # THE ERROR THAT MUST NEVER HAPPEN. The holder is editing files in its desk and
  # writing nothing at all to the board — the exact 2026-08-13 session, which a
  # board-keyed liveness rule would have declared dead mid-edit. Desk evidence
  # alone keeps the claim, with every other channel silent and the board age far
  # past the threshold.
  def test_a_holder_writing_its_desk_is_never_abandoned_however_quiet_the_board
    refute ClaimLease.abandoned?(desk_touched: true,
                                 progress_age: 100 * ClaimLease::DESK_IDLE_SECONDS,
                                 gate_in_flight: false,
                                 awaiting_approval: false),
           "a session actively writing its worktree is WORKING — stealing its desk costs the work itself"
  end

  # The bug this task exists to fix: a terminal left open renewing forever. Every
  # channel silent, and only then does the claim let go.
  def test_a_holder_with_no_desk_activity_and_no_board_activity_is_abandoned
    assert ClaimLease.abandoned?(desk_touched: false,
                                 progress_age: ClaimLease::DESK_IDLE_SECONDS + 60,
                                 gate_in_flight: false,
                                 awaiting_approval: false)
  end

  # A claim taken and immediately walked away from produces NO durable artifact
  # ever. Silence on both channels is still silence — this is the one place a nil
  # progress fact corroborates rather than excuses.
  def test_a_holder_that_never_produced_anything_and_never_touched_its_desk_is_abandoned
    assert ClaimLease.abandoned?(desk_touched: false, progress_age: nil)
  end

  # --- Every unknown, and every positive signal, keeps the desk -------------

  # The load-bearing third answer. nil is "we could not tell" — no desk bound to
  # the task, an unreadable root, a walk out of budget — and it must short-circuit
  # BEFORE any other channel is consulted, so a task with no board activity at all
  # still cannot be declared abandoned on an unread desk.
  def test_an_unreadable_desk_is_never_abandoned
    refute ClaimLease.abandoned?(desk_touched: nil, progress_age: nil),
           "no evidence is not evidence of absence — an unknown desk must never free a claim"
    refute ClaimLease.abandoned?(desk_touched: nil,
                                 progress_age: 100 * ClaimLease::DESK_IDLE_SECONDS),
           "an unknown desk outranks even a very old board fact"
  end

  # A cert writes nothing into the desk while it runs, and the measured g1_cert
  # p99 is 94 minutes. Without this channel a long green cert is indistinguishable
  # from a walked-away terminal.
  def test_a_gate_in_flight_keeps_the_desk_through_a_silent_cert
    refute ClaimLease.abandoned?(desk_touched: false, progress_age: nil, gate_in_flight: true)
  end

  # Parked on the operator is not abandoned. The agent is right to be doing
  # nothing, and the task record says so.
  def test_a_task_awaiting_operator_approval_is_never_abandoned
    refute ClaimLease.abandoned?(desk_touched: false, progress_age: nil, awaiting_approval: true)
  end

  # The board channel still counts on its own — a holder working through the API
  # rather than the filesystem reads as alive.
  def test_recent_board_progress_keeps_the_desk_even_with_a_quiet_desk
    refute ClaimLease.abandoned?(desk_touched: false,
                                 progress_age: ClaimLease::DESK_IDLE_SECONDS - 1)
  end

  def test_the_idle_window_is_tunable_per_call
    assert ClaimLease.abandoned?(desk_touched: false, progress_age: 700, idle_after: 600)
    refute ClaimLease.abandoned?(desk_touched: false, progress_age: 500, idle_after: 600)
  end

  # --- The threshold, asserted as a PROPERTY against its own corpus ---------
  #
  # Same discipline as the quiet threshold above, and for the same reason: a test
  # that pins the literal cannot see the constant drift out from under its
  # evidence. This one is TWO-SIDED, because a desk-idle threshold can fail in
  # both directions — too low steals from live workers, too high is inert.

  # No measured WORKING gap may ever be read as abandonment. Drift the constant
  # below the corpus and this goes red, whatever number it drifts to.
  def test_no_measured_working_gap_is_ever_read_as_abandonment
    %i[working_p50 working_p90 working_p95 working_p99 working_max].each do |percentile|
      gap = ClaimLease::MEASURED_DESK_GAP_SECONDS.fetch(percentile)

      refute ClaimLease.abandoned?(desk_touched: false, progress_age: gap),
             "#{percentile} (#{gap}s) is a MEASURED WORKING gap, but the idle threshold " \
             "(#{ClaimLease::DESK_IDLE_SECONDS}s) calls it abandoned — that steals a desk from a live worker"
    end
  end

  def test_the_threshold_clears_the_worst_measured_working_gap_by_its_stated_margin
    worst = ClaimLease::MEASURED_DESK_GAP_SECONDS.fetch(:working_max)

    assert_operator ClaimLease::DESK_IDLE_SECONDS, :>, worst,
                    "the threshold must exceed the worst measured WORKING gap it claims to clear"
    assert_operator ClaimLease::DESK_IDLE_SECONDS, :>=, worst * ClaimLease::DESK_IDLE_SAFETY_FACTOR,
                    "the threshold must honour the safety factor its own comment derives it from"
  end

  # ...and it must still BITE, or "clear the working band" is satisfied by making
  # it enormous and nothing is ever freed. The bound is stated against the
  # evidence: the TYPICAL walked-away desk (the abandoned band's median) has to be
  # caught, or this whole change is decoration.
  def test_the_typical_abandoned_desk_is_still_caught
    typical = ClaimLease::MEASURED_DESK_GAP_SECONDS.fetch(:abandoned_p50)

    assert_operator ClaimLease::DESK_IDLE_SECONDS, :<, typical,
                    "a threshold above the median abandoned gap frees nothing — the lease outlives the session again"
    assert ClaimLease.abandoned?(desk_touched: false, progress_age: typical)
  end

  # --- too_young_to_abandon?: a desk cannot be idle longer than it has existed ---
  #
  # The floor under the reclaim guard. A brand-new worktree is git-identical to a
  # merged one — clean, nothing ahead of base — so `cleanup --reclaim`'s git test
  # passes on it vacuously, and on 2026-08-13 a sweep destroyed a live desk on the
  # strength of that pass. Age is the one channel that separates "nobody has written
  # here YET" from "nobody will write here again".

  def test_a_newborn_desk_is_too_young_to_call_abandoned
    assert ClaimLease.too_young_to_abandon?(30),
           "a desk half a minute old has not had time to be abandoned, however clean it looks"
  end

  def test_a_desk_older_than_the_idle_window_is_old_enough_to_judge
    refute ClaimLease.too_young_to_abandon?(ClaimLease::DESK_IDLE_SECONDS + 1),
           "past the idle window, age stops protecting and the other channels decide — " \
           "a floor that never lifts is a guard that never frees anything"
  end

  # THE THRESHOLD IS THE SAME ONE, asserted as a property rather than a number.
  # abandoned? means "silent for DESK_IDLE_SECONDS"; a desk younger than that has
  # not existed long enough to have produced that silence. If these two ever drift
  # apart, one of them is asserting more than the evidence carries.
  def test_the_floor_is_exactly_the_idle_window_it_is_derived_from
    boundary = ClaimLease::DESK_IDLE_SECONDS

    assert ClaimLease.too_young_to_abandon?(boundary - 1)
    refute ClaimLease.too_young_to_abandon?(boundary)
  end

  def test_an_undatable_desk_keeps_itself
    assert ClaimLease.too_young_to_abandon?(nil),
           "unknown age must resolve to KEEP, so a caller that forgets to check nil still fails safe"
  end

  # --- holder_scoped: one notion of 'is the holder working', two consumers ------
  #
  # bin/task's heartbeat and bin/agent-worktree's reclaim guard read the same board
  # payload for the same fact. A MISSING key is an older board (an unknown), and the
  # task-wide fallback is the conservative direction — it counts everyone's work, so
  # it can only keep a desk, never free one.

  def test_holder_scoped_prefers_the_holder_fact_when_the_board_publishes_one
    task = { "holder_liveness_seconds_ago" => 30, "progress_seconds_ago" => 9_000 }

    assert_equal 30, ClaimLease.holder_scoped(task, "holder_liveness_seconds_ago", "progress_seconds_ago")
  end

  def test_holder_scoped_falls_back_to_the_task_wide_twin_on_an_older_board
    task = { "progress_seconds_ago" => 9_000 }

    assert_equal 9_000, ClaimLease.holder_scoped(task, "holder_liveness_seconds_ago", "progress_seconds_ago")
  end

  # PRESENT-AND-NIL is a real answer ("nothing has ever landed here"), not a missing
  # key, and must pass through as one rather than silently reaching for the twin.
  def test_a_present_nil_holder_fact_is_an_answer_not_a_missing_key
    task = { "holder_liveness_seconds_ago" => nil, "progress_seconds_ago" => 9_000 }

    assert_nil ClaimLease.holder_scoped(task, "holder_liveness_seconds_ago", "progress_seconds_ago")
  end

  def test_holder_scoped_survives_a_nil_payload
    assert_nil ClaimLease.holder_scoped(nil, "holder_gate_in_flight", "gate_in_flight")
  end
end
