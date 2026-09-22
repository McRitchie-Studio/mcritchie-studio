# frozen_string_literal: true

require_relative "../../lib/claim_lease"

# AnchorHeartbeat — the ONE answer to "is the agent behind this anchor still
# WORKING", as opposed to "is its process still in the process table".
#
# WHY IT EXISTS. Every renewing lease in this house anchors its renewer to a
# long-lived `claude`/`codex` process and asks ONE question of it, through a
# lambda that is byte-identical in all four lanes:
#
#     alive: -> { SessionIdentity.process_alive?(pid, start) }
#
#     bin/task                     (claim-renew-loop)  the BUILD claim
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
# A HELD-BUT-ABANDONED DESK IS WORSE THAN A LAPSED ONE, which is why this is worth a
# file. `bin/agent-worktree cleanup --reclaim` correctly withholds a claimed desk and
# every other session correctly refuses to steal one, so the two safety rules compose
# into a DEADLOCK: the desk cannot be reclaimed, cannot be taken, and the work inside
# it is invisible to every sweep. A lapsed lease is recoverable; this is not.
#
# WHY ONLY ONE LANE HAD AN ANSWER. The BUILD lane already compensates —
# bin/lib/build_claim_renewer.rb's third condition runs `ClaimLease.abandoned?` on
# every beat (desk mtimes + holder-scoped board progress + gate-in-flight). The
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
  # HOW LONG AN ANCHOR MAY GO QUIET BEFORE IT STOPS COUNTING AS A HOLDER.
  #
  # DERIVED, NOT CHOSEN, and deliberately NOT a new number. ClaimLease's
  # PROGRESS_QUIET_SECONDS (11_250s = 3h07m30s) is this house's measured ceiling on
  # how long HEALTHY work goes without producing a durable artifact — the quietest
  # measured healthy window, cleared by half again. A session's narration markers are
  # durable artifacts of exactly that kind, so the question they answer is the
  # question that constant was derived for.
  #
  # There is precedent for this exact reuse: BuildClaimRenewer::DESKLESS_LIFETIME_SECONDS
  # is the same constant, bounding the same situation (a renewer that cannot see its
  # holder) with the same argument — holding a claim we cannot observe for LONGER than
  # healthy work is ever observed to go quiet asserts more than the evidence carries.
  #
  # NOT DESK_IDLE_SECONDS (1h29m), the abandonment gate's bound, though it is the
  # nearer-looking number. That one was derived from a corpus of desk EDIT gaps, and
  # narration gaps are a different population that has not been measured. Borrowing a
  # threshold across populations is how a bound comes to assert something nobody
  # measured; the conservative constant is the honest one until that corpus exists.
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
  #                 The 2026-09-22 orphan. STOPS renewing.
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
  #
  # +fallback+ names the ONE thing that might still renew it, for the single lane
  # where that is true: the BUILD claim is also renewed by bin/statusline. It is a
  # parameter rather than a sentence in three of the four messages because a claim
  # that says "unless a status line renews it" in a HEADLESS run is not a caveat, it
  # is a false reassurance — a headless agent shell paints nothing, which is the
  # whole reason the detached renewer exists (bin/lib/build_claim_renewer.rb).
  def unanchored_notice(subject:, ttl_seconds:, fallback: nil)
    tail = fallback ? " Only #{fallback} can renew it now, and only while that is running." : ""

    "no agent process to anchor a renewer to — NOTHING will renew this #{subject}, " \
      "so it lapses in ~#{ClaimLease.humanize_age(ttl_seconds)} and the rest of this run is " \
      "UNPROTECTED. Continuing anyway: the claim guards against a second conductor, " \
      "it is not required for this run to be correct.#{tail}"
  end
end
