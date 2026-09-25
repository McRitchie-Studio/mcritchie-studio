# frozen_string_literal: true

require_relative "../../lib/claim_lease"

# AnchorHeartbeat — the ONE answer to "is the agent behind this anchor still
# WORKING", as opposed to "is its process still in the process table".
#
# WHY IT EXISTS. Every renewing lease in this house anchors its renewer to a
# long-lived `claude`/`codex` process and asks ONE question of it, through a
# lambda that is byte-identical in all three lanes:
#
#     alive: -> { SessionIdentity.process_alive?(pid, start) }
#
#     bin/lib/review_claim_cli.rb  (#renew_loop)       the REVIEW claim
#     bin/lib/release_claim_cli.rb (#renew_loop)       the RELEASE conductor claim
#     bin/devops-shift             (#renew_loop)       the DEVOPS SHIFT lease
#
# Named by METHOD, not by line: wiring this seam moves every one of those lines, so a
# pinned :NNN would be stale the moment it was written. The set is pinned as a TEST
# instead (test/lib/anchor_heartbeat_test.rb), which cannot drift.
#
# `process_alive?` is `ps -o lstart=` compared to a recorded start signature. It is
# SOUND in one direction only: a signature that no longer matches proves the holder
# is gone. It proves NOTHING in the other direction, because a process that has
# stopped working does not leave the process table.
#
# THE MEASURED INCIDENT, 2026-09-22. A `codex --yolo` session (pid 51595, started
# Mon Sep 21 19:45:57 2026) hit a usage limit and was shut down by the operator. The
# process stayed resident, so `process_alive?` kept answering TRUE, so its detached
# renewer (pid 62041) kept advancing the lease — measured moving 03:50:45Z →
# 03:52:47Z across a 75-second read. Behind that lease sat
# turf-monster/.worktrees/fix-inline-violet-text-contrast holding 124 UNCOMMITTED
# lines across 3 files that nobody was coming back for.
#
# WHAT THE SEAM DOES TO THAT INCIDENT, measured rather than implied — because the
# paragraph above reads as though this file catches it, and it does not.
#
# The incident session is 01a0c6e1-df50-7a60-afb6-77694fd40444. Its newest marker
# visible to `SessionMarkers.last_signal_at` is `.open-activity`, mtime 20:22:09
# MDT (its `.json` feature marker is older still, 20:12:00). The orphan was
# OBSERVED at 03:52:47Z = 21:52:47 MDT, so `signal_age` was 5_438s against a bound
# of 11_250s: `verdict` would have answered :working and the renewer WOULD HAVE
# RENEWED. It bites at 23:29:39 MDT, 97 minutes later.
#
# So the honest claim is BOUNDING, not catching: this converts an unbounded wedge
# into one that ends in about three hours. That is the whole improvement, and it is
# a real one — the lease was previously immortal.
#
# The tighter bound would not have bought much, and the measurement is the reason
# to stop arguing about it: NARRATION_QUIET_SECONDS (5_391s) bites at 21:52:00,
# FORTY-SEVEN SECONDS before the observation. Catching an incident by 47 seconds is
# noise, not detection — it is an artifact of when somebody happened to look. A
# bound picked to win that margin would pay the false-stop risk for it.
#
# A HELD-BUT-ABANDONED DESK IS WORSE THAN A LAPSED ONE, which is why this is worth a
# file. `bin/agent-worktree cleanup --reclaim` correctly withholds a claimed desk and
# every other session correctly refuses to steal one, so the two safety rules compose
# into a DEADLOCK: the desk cannot be reclaimed, cannot be taken, and the work inside
# it is invisible to every sweep. A lapsed lease is recoverable; this is not.
#
# WHY THE LANES DIFFERED. The BUILD lane (retired in devops-v3: the desk is the
# build claim) ran `ClaimLease.abandoned?` on every beat. The
# REVIEW lane compensates with a shortened lifetime cap. The RELEASE and SHIFT lanes
# compensate with NOTHING: they pass a bare `ShiftRenewer.run` whose only brake short
# of the 12-hour safety cap is the anchor check above. That asymmetry is not a
# decision anybody made; it is what happens when a fix lands at a CALL SITE and the
# SEAM stays unchanged, so the next three lanes are written against the old seam.
# This file IS the seam, so a lane cannot be written without one.
#
# WHAT COUNTS AS A SIGN OF LIFE — and what deliberately does not.
#
#   IT DOES  — the session's own narration markers under
#              <projects>/.agents/sessions/<id>.*, rewritten by bin/atomic-event on
#              every `bin/agent-activity start|next|end`. A session emits these BY
#              WORKING, which is the property that matters.
#   IT DOES NOT — the statusline THROTTLE markers (`.heartbeat`, `.shift-heartbeat`,
#              `.mascot-heal`). bin/statusline writes them whenever Claude Code
#              PAINTS, so they measure a terminal, not an agent. lib/claim_lease.rb
#              already settled this in the abandonment gate's header, from the
#              2026-08-13 incident: "A heartbeat proves a TERMINAL IS OPEN. Nothing
#              more." Counting them here would rebuild the immortal lease that gate
#              was written to remove — an open terminal behind a dead agent would
#              renew forever, which is the exact bug above wearing a different hat.
#              SessionMarkers.last_signal_at owns that exclusion; see its header.
#
# NOTHING A RENEWER WRITES MAY COUNT AS ITS OWN EVIDENCE, and that was checked
# rather than assumed: all four renew-loop bodies were read (the four call sites
# above) and NONE writes a marker. The `.…-renewer-…` pid markers are written by the
# CLAIMING process before the loop is spawned, never by the loop. A renewer that
# refreshed a marker it then read as proof of life would be a lease certifying
# itself, which is indistinguishable from the defect this file closes.
#
# EVERY UNCERTAINTY KEEPS THE CLAIM. This file can only ever STOP a renewal, so its
# failure mode is stealing a live holder's lease — and the release lane it now sits
# in front of is the production deploy path. So the only verdict that stops a
# renewal on this file's account is a POSITIVE reading: markers were found AND they
# are older than the bound. No markers, an unreadable store, a raised exception, a
# session we cannot name — all answer :unverified, which HOLDS. The pre-existing
# residency check is untouched and still decides :gone on its own terms.
#
# Pure and injectable — `verdict` reads no clock, no process table and no disk, so
# the decision is tested as arithmetic. The one IO method is a thin, rescued reader.
module AnchorHeartbeat
  # THE NARRATION-GAP CORPUS — as data rather than prose, so the guard test can
  # READ it. lib/claim_lease.rb already keeps its two corpora this way, for the
  # reason it states: "A number in prose cannot be checked. A number in a constant
  # can." This file shipped its threshold argument in prose, and the prose was
  # wrong (see the correction under IDLE_AFTER_SECONDS). So the corpus lands here.
  #
  # THE MEASUREMENT. Consecutive differences between a session's own narration
  # writes, counted from Claude transcripts as verified `tool_use` Bash invocations
  # of `agent-activity|atomic-event (start|next|end|close-open)` — i.e. the very
  # writes `SessionMarkers.last_signal_at` reads the mtimes of. Bands split at a
  # 1-hour separator, exactly as MEASURED_DESK_GAP_SECONDS splits its own.
  #
  #   n = 3_112 gaps across 125 sessions, 143 transcripts, to 2026-09-22.
  #
  # FIRST TAKEN at n=381/13 sessions (jasper, 2026-09-22) and INDEPENDENTLY
  # RE-DERIVED here over the whole transcript store, 8x larger. The two figures the
  # threshold rests on reproduced UNCHANGED — `working_max` 3_594s and
  # `abandoned_min` 3_664s in both. The pooled percentiles did NOT reproduce
  # (p90 12_939s → 7_082s), so they are recorded as the distribution they are and
  # nothing is derived from them; an earlier draft of this sentence claimed EVERY
  # band number reproduced, which the very next clause contradicts.
  #
  # AND `working_max` REPRODUCING IS WEAK EVIDENCE, stated because a control that
  # cannot move proves nothing. `working_max` is BY DEFINITION the largest gap below
  # the 1-hour separator, so it saturates against that cutoff: at n=3_112 it sits 6s
  # under it, leaving six seconds of room to differ. It would have reproduced
  # whatever the data did. What actually supports this corpus is that a reviewer
  # re-derived it from scratch and got the same numbers (carl's light, 2026-09-23),
  # not the stability of a saturated maximum. The same idiom pins
  # ClaimLease::MEASURED_DESK_GAP_SECONDS, whose `working_max` is 44s under the
  # same cutoff.
  #
  # RE-DERIVE, DO NOT RE-COPY — and NO COMMITTED SCRIPT DERIVES THIS YET, which is
  # the honest remaining gap in the record. Re-deriving means re-implementing the
  # measurement above, so read its population definition strictly: the gaps are
  # between one session's NARRATION writes — the marker mtimes
  # `SessionMarkers.last_signal_at` reads — NOT between all of a transcript's
  # message timestamps. The two are not close: the same store answers n=3_112 over
  # 125 sessions for the former and n≈992_000 over 3_143 sessions for the latter
  # (measured 2026-09-23 while checking exactly this), and the second population
  # lands `working_max` at 3_596s, 2s from this constant's 3_594s, so a wrong
  # population reproduces the number closely enough to look like confirmation.
  # Anyone committing a script for this should name it here and delete this note.
  #
  # The percentile ESTIMATOR is not recorded and the percentiles are not
  # reproducible as written (ceil-index, floor-index and interpolated all differ).
  # Since nothing derives from them, that is a gap in the record, not in the bound.
  #
  # THE SEPARATOR IS LESS STABLE HERE THAN IT IS FOR DESK EDITS, and that is the
  # caveat this corpus carries. claim_lease can say its derivation barely moves
  # when the 1-hour separator does (1h → 5_334s, 2h → 7_347s, a 38% move).
  # Narration's moves nearly twice as far: 1h → 5_391s, 1.5h → 8_009s,
  # 2h → 10_679s, a 98% move. The gutter is tighter too — 70s here against the
  # desk corpus's 339s — because a narration gap has no natural floor the way an
  # edit does. So the bound below is a REAL number with a SOFT band split, which
  # is a further reason not to park a liveness decision on it.
  MEASURED_NARRATION_GAP_SECONDS = {
    working_p50: 268,       # 4.5m  — median gap between one session's narration writes
    working_p90: 1_357,     # 23m
    working_p95: 1_962,     # 33m
    working_p99: 3_047,     # 51m
    working_max: 3_594,     # 59.9m — the binding number: the quietest working session
    abandoned_min: 3_664,   # 61m   — the busiest abandoned session (a 70s gutter)
    abandoned_p50: 19_088   # 5.3h  — the typical walked-away session
  }.freeze

  NARRATION_IDLE_SAFETY_FACTOR = 1.5

  # What a population match WOULD have produced. Derived by the same method as
  # ClaimLease::DESK_IDLE_SECONDS, from the population that actually writes the
  # markers this file reads. It is NOT the bound — see IDLE_AFTER_SECONDS — and it
  # is here so the bound's looseness is a measured fact rather than an assertion.
  NARRATION_QUIET_SECONDS =
    (MEASURED_NARRATION_GAP_SECONDS[:working_max] * NARRATION_IDLE_SAFETY_FACTOR).ceil # 5_391s

  # HOW LONG AN ANCHOR MAY GO QUIET BEFORE IT STOPS COUNTING AS A HOLDER.
  #
  # A DELIBERATE CHOICE OF THE LOOSER BOUND — not a population match, and the
  # earlier draft of this comment claimed otherwise. It argued that "a session's
  # narration markers are durable artifacts of exactly that kind, so the question
  # they answer is the question that constant was derived for". That is FALSE
  # against ClaimLease's own definition: lib/claim_lease.rb defines `progress_age`
  # as seconds since a task produced a durable artifact, and ENUMERATES them — a
  # TaskEvent (stage move / intent / cert checkpoint) or a GateRun open/lane/close.
  # `Task#progress_evidence` reads exactly those two associations. Narration writes
  # `agent_activity` rows and marker files; neither is in that enumeration, and the
  # 243 building windows PROGRESS_QUIET_SECONDS was derived from are windows of
  # BOARD silence. Two reviewers reached this independently at PR 1523's review.
  #
  # So there were two borrowed bounds on offer, and the constant above measures
  # which one the population actually supports:
  #
  #   NARRATION_QUIET_SECONDS           5_391s (1h30m)  ← the population match
  #   ClaimLease::PROGRESS_QUIET_SECONDS 11_250s (3h07m) ← what this uses
  #
  # THE NUMBER IS STILL RIGHT, AND THE REASON IS THE ASYMMETRY, NOT THE POPULATION.
  # This file can only ever STOP a renewal, so a bound that is too TIGHT steals a
  # live holder's lease — and one of the lanes behind it is the production deploy
  # path. A bound that is too LOOSE leaves an already-orphaned claim held for
  # longer, which is the state we were in anyway. When the two errors cost that
  # differently, taking the looser of two borrowed bounds is the correct call, and
  # it stays correct whichever population either was drawn from. The measurement
  # above prices the choice rather than excusing it: the window is 2.09x the one
  # narration's own corpus supports.
  #
  # It also clears healthy narration by a wide margin either way — the quietest
  # working session in a 3_112-gap corpus went 59.9 minutes, against a bound of
  # 187.5.
  #
  # IDLE_AFTER_SECONDS is a SLIDING WINDOW that resets on every narration write,
  # so a busy session never reaches it — the looseness errs toward HOLD.
  #
  # WHAT IT COSTS, stated plainly: an anchor whose session goes quiet for longer than
  # this while genuinely working loses its lease. The lease then lapses on the
  # ordinary TTL — recoverable, and for the build lane re-adopted by the very next
  # beat from the task's bound desk. That is the cheap direction, by design.
  IDLE_AFTER_SECONDS = ClaimLease::PROGRESS_QUIET_SECONDS

  # The verdicts. Exactly two of them stop a renewal.
  #
  #   :working    — resident, and its session left a mark inside the window
  #   :unverified — resident, and NOTHING can vouch either way (no markers, an
  #                 unreadable store, no session id). Holds the claim: no evidence
  #                 is not evidence, and this file never frees a lease on silence
  #                 it cannot attribute.
  #   :idle       — resident, but its session has been quiet past IDLE_AFTER_SECONDS.
  #                 What eventually ends the 2026-09-22 orphan — 97 minutes after
  #                 it was observed, not at the moment of it (see the header).
  #                 STOPS renewing.
  #   :gone       — the process is not the one we anchored to (exited, or the pid was
  #                 reused). The pre-existing residency verdict. STOPS renewing.
  STOPS_RENEWING = %i[gone idle].freeze

  module_function

  # The whole decision, as arithmetic.
  #
  # +resident+   — SessionIdentity.process_alive?(pid, start). false is decisive.
  # +signal_age+ — seconds since this session last left a mark, or nil for UNKNOWN.
  #                nil and a number are different answers and must stay different:
  #                folding nil to a large number would turn "we could not look" into
  #                "it has been quiet for ages", which frees leases on no evidence.
  def verdict(resident:, signal_age:, idle_after: IDLE_AFTER_SECONDS)
    return :gone unless resident
    return :unverified if signal_age.nil?
    return :idle if signal_age > idle_after

    :working
  end

  # The boolean the `alive:` seam wants. ONLY :gone and :idle stop a renewal.
  def holding?(verdict) = !STOPS_RENEWING.include?(verdict)

  # The `alive:` lambda every lane passes to ShiftRenewer, replacing the bare
  # residency probe. Rescues EVERYTHING to the residency answer alone, because
  # ShiftRenewer does not rescue `alive.call` — an exception here would kill the
  # renewer outright and drop a live holder's lease, which is a strictly worse
  # failure than the one this file is fixing.
  #
  # +signal+ is a callable returning the session's signal age (or nil) so the lane's
  # IO stays injectable and this stays testable without a marker store.
  def alive_check(resident:, signal:, idle_after: IDLE_AFTER_SECONDS)
    lambda do
      here = resident.call
      return false unless here

      holding?(verdict(resident: true, signal_age: signal.call, idle_after: idle_after))
    rescue StandardError
      true # resident, and the liveness read failed — the pre-existing behaviour
    end
  end

  # Seconds since this session last left a mark, or nil when nothing can vouch.
  # Thin by design: SessionMarkers owns WHICH markers count (see its header), this
  # owns only the arithmetic and the rescue.
  def signal_age(session:, projects_dir:, now: Time.now, markers: SessionMarkers)
    return nil if session.to_s.strip.empty?

    touched = markers.last_signal_at(session, projects_dir)
    return nil if touched.nil?

    age = now - touched
    age.negative? ? 0 : age
  rescue StandardError
    nil
  end

  # --- Face two of the same defect: no anchor at all -------------------------
  #
  # The loop above answers "my anchor stopped working". This answers the other
  # half, which fires BEFORE any renewer exists: `SessionIdentity.agent_process`
  # returned nil, so no renewer is started at all and the lease dies one TTL in
  # while the act runs on for minutes.
  #
  # MEASURED 2026-09-22, live, during `bin/release prepare`:
  #
  #   release-claim: note — no agent process to anchor a renewer to; this assembler
  #                  claim lapses in ~120s unless something renews it.
  #   release-claim: ✅ rel-20260922-ca1c0b assembler claimed
  #   ...at the end of the run:
  #   release-claim: rel-20260922-ca1c0b assembler was not held by this session — nothing released.
  #
  # Reproduced here rather than inferred: a process spawned the way every renewer is
  # spawned (`Process.spawn(pgroup: true)` + `Process.detach`) and outliving the
  # shell that launched it reparents to ppid 1, and `SessionIdentity.agent_process`
  # then walks an ancestry containing no agent at all and returns nil. A plain shell,
  # a cron run and CI reach the same branch by the same route.
  #
  # REFUSING TO ACT IS NOT THE FIX, and this is the part worth holding on to. That
  # sweep COMPLETED CORRECTLY without a live claim — the claim is a collision guard,
  # not a correctness precondition — so an act that refused to start because it could
  # not anchor a renewer would wedge the release lane on a hiccup while fixing
  # nothing. The honest remedy is to ACT AND SAY SO.
  #
  # WHAT THE OLD WORDING GOT WRONG, in all four lanes: "lapses in ~120s unless
  # something renews it" names a condition that is already decided. Nothing WILL renew
  # it — that is precisely the branch we are on — and the sentence prints immediately
  # ABOVE the "✅ claimed" line, so the one warning the operator gets reads as a
  # footnote to a success. The run then ends with "was not held by this session",
  # which reads like somebody else took the claim rather than like it expired
  # unattended two minutes in.
  #
  # +subject+ is the lane's own noun ("assembler claim", "shift", "review").
  def unanchored_notice(subject:, ttl_seconds:)
    "no agent process to anchor a renewer to — NOTHING will renew this #{subject}, " \
      "so it lapses in ~#{ClaimLease.humanize_age(ttl_seconds)} and the rest of this run is " \
      "UNPROTECTED. Continuing anyway: the claim guards against a second conductor, " \
      "it is not required for this run to be correct."
  end
end
