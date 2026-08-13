# frozen_string_literal: true

require "time"

# The build-stage claim lease — the math that decides who owns a task while it's
# being built. A claim is held by a LIVE INSTANCE, not a bare session id:
#
#   claimed_session  — the agent session that holds the claim (CLAUDE_CODE_SESSION_ID)
#   claim_nonce      — a per-PROCESS-instance token (see bin/task#claim_nonce). Two
#                      terminals running `claude --resume <same id>` share the
#                      session id but are different OS processes → different nonce.
#   claim_expires_at — an ISO8601 TTL lease, renewed by the heartbeat (bin/statusline)
#                      ONLY while the holder can be shown to be working (see
#                      `abandoned?` below). No renewal for > TTL ⇒ the lease lapses
#                      ⇒ the task is reclaimable. The renewal used to be
#                      unconditional, which meant an open terminal held a desk
#                      forever whether or not an agent was on it.
#
# Why a nonce and not just the session id: the operator's terminal-A / terminal-B
# case. `claude --resume X` in a second terminal forks the SAME transcript (same
# session id) but is a NEW process, so the nonce differs and the gate sees a
# second live instance of one session. The same mechanism catches two DIFFERENT
# sessions grabbing one task (the original duplicate-work bug).
#
# Plain Ruby (no Rails) so the standalone bin/task CLI can `require_relative` it,
# while the Task model and the unit tests use the very same source of truth.
# Every function is PURE: inject `now:` (and the mover identity) — nothing here
# reads the clock, the environment, or the process tree.
module ClaimLease
  # The lease TTL. 120s comfortably outlives the ~5s bin/statusline render cadence
  # (≈24 renders of slack) so a brief stall or a throttled heartbeat never falsely
  # expires a live claim — yet a closed/crashed terminal frees the task within two
  # minutes. The renewer and the reader share this constant, so the "last heartbeat
  # Ns ago" the gate reports is exact, not an estimate.
  DEFAULT_TTL_SECONDS = 120

  CLAIM_KEYS = %w[claimed_session claim_nonce claim_expires_at].freeze

  # Disposition of a stored claim relative to the mover asking to build it:
  #   :unclaimed     — no one holds it
  #   :expired       — a claim exists but its lease lapsed, or carries NO expiry
  #                    at all → silently reclaimable (a dead session stops
  #                    renewing, so a dead-session lease surfaces here; the
  #                    renewer always writes an expiry, so a blank one is a
  #                    never-renewed relic, not a live builder)
  #   :corrupt       — a claim exists but its expiry is PRESENT and UNPARSEABLE →
  #                    unverifiable. "We could not check" is not "the builder is
  #                    gone": destructive consumers (the reclaim guard) must
  #                    WITHHOLD (see live?), while the build-claim gate keeps its
  #                    fail-open posture — it branches only on :held_by_other, and
  #                    a re-claim WRITES a fresh lease (renewed), healing the
  #                    corruption; destroying a desk heals nothing.
  #   :same_instance — held by THIS live instance (session AND nonce match) → re-move is fine
  #   :held_by_other — held by a DIFFERENT, still-live instance → the gate warns/refuses
  #
  # Like :expired, :corrupt is a lease-level disposition and outranks identity:
  # even the holder reads its own garbled lease as :corrupt (its next claim/
  # heartbeat rewrites a parseable one).
  #
  # claim: a hash (devops slice) with the CLAIM_KEYS (any may be nil/absent).
  def self.evaluate(claim, session:, nonce:, now: Time.now)
    claim ||= {}
    stored_session = claim["claimed_session"].to_s
    return :unclaimed if stored_session.empty?
    return :corrupt if corrupt_expiry?(claim)

    expires = parse_time(claim["claim_expires_at"])
    # Fail OPEN on a missing expiry: a blank lease is treated as lapsed so a
    # never-renewed claim frees the task rather than locking it forever.
    return :expired if expires.nil? || expires <= now

    return :held_by_other unless stored_session == session.to_s

    # Same session — now decide whether it's the SAME live instance or a second
    # terminal of it. Distinguish the two ONLY when BOTH nonces are known: a BLANK
    # on either side means "instance unknown", and the degrade contract
    # (SessionIdentity.nonce) is a session-only lease, so the same session is the
    # same holder. Reading blank-vs-populated as a DIFFERENT instance is the
    # ship-claim-blank-nonce bug: a detached heartbeat renewal blanked the STORED
    # nonce, then the owner's populated nonce was compared against blank and the
    # true owner was locked out of its own task. Absence of a signal must never
    # read as an affirmative negative.
    stored_nonce = claim["claim_nonce"].to_s.strip
    current_nonce = nonce.to_s.strip
    if !stored_nonce.empty? && !current_nonce.empty? && stored_nonce != current_nonce
      :held_by_other # two terminals of one session (both nonces resolved, and differ)
    else
      :same_instance
    end
  end

  # True when a claim is held by anyone and cannot be ruled lapsed — a confirmed
  # non-expired lease OR a corrupt (unverifiable) one. This is the liveness check
  # the resume control asks ("session looks active in another terminal") and the
  # question the reclaim guard's WITHHOLD decision rides on, so it must err
  # toward "possibly live": a garbled expiry means we could not check, and a desk
  # we cannot verify must never read as free on a destroy path. A BLANK expiry
  # stays false — the renewer always writes one, so blank means never-renewed,
  # not unreadable.
  def self.live?(claim, now: Time.now)
    claim ||= {}
    return false if claim["claimed_session"].to_s.empty?
    return true if corrupt_expiry?(claim)

    expires = parse_time(claim["claim_expires_at"])
    !expires.nil? && expires > now
  end

  # True when a held claim carries an expiry that is PRESENT but unparseable —
  # the unverifiable state. Distinct from absent/blank (:expired territory,
  # fail-open) and from a session-less hash (no claim at all). Exposed so
  # consumers that need the distinction (e.g. an honest "expiry unverifiable"
  # hold reason, vs. live?'s merged possibly-live answer) can ask directly.
  def self.corrupt_expiry?(claim)
    claim ||= {}
    return false if claim["claimed_session"].to_s.empty?

    text = claim["claim_expires_at"].to_s.strip
    !text.empty? && parse_time(text).nil?
  end

  # Seconds since the holder's last heartbeat, derived from the lease expiry and
  # the shared TTL (expiry = last_heartbeat + TTL). nil when there's no parseable
  # lease; never negative.
  def self.heartbeat_age(claim, now: Time.now, ttl: DEFAULT_TTL_SECONDS)
    claim ||= {}
    expires = parse_time(claim["claim_expires_at"])
    return nil if expires.nil?

    age = ttl - (expires - now)
    age.negative? ? 0 : age.round
  end

  # --- Progress, which is NOT liveness -------------------------------------
  #
  # The lease above attests exactly one thing: A TERMINAL IS RENDERING. It is
  # renewed by bin/statusline's ~5s status-line paint, so it survives a wedged
  # agent — on 2026-07-13 a session sat 28 minutes making no durable write while
  # its lease stayed green, and the board read that green as "progressing".
  # It never meant that. Liveness and progress are two different facts, and the
  # cure is to REPORT BOTH, not to swap one for the other.
  #
  # `progress_age` is the second fact: seconds since this task last produced a
  # DURABLE artifact (a TaskEvent — stage move / intent / cert checkpoint — or a
  # GateRun open/lane/close). The caller supplies it; this module stays pure.
  #
  # WHY THERE IS NO "STALLED" VERDICT HERE, and why you should not add one.
  #
  # THE EVIDENCE, as data rather than prose. 243 live `building` windows on the
  # prod board over the 14 days to 2026-07-13: for each, the longest stretch of
  # board silence inside a window that ended in healthy work, plus every g1_cert
  # duration in the same corpus. These are the numbers the threshold below answers
  # to, so they live in a constant the guard test can READ. The previous cut of
  # this file kept them in a comment and set a threshold five minutes BELOW the
  # p99 it claimed to clear — a gate contradicting its own evidence, in the very
  # PR about gates that assert what they cannot support. A number in prose cannot
  # be checked. A number in a constant can, and test/lib/claim_lease_test.rb does.
  MEASURED_SILENCE_SECONDS = {
    healthy_p50: 1_560, # 26m   — median board-write silence inside a HEALTHY window
    healthy_p90: 3_960, # 66m
    healthy_p99: 7_500, # 125m  — the binding number: the quietest 1% of healthy work
    cert_p50: 126,      # 2.1m  — g1_cert wall-clock, which writes nothing while it runs
    cert_p90: 780,      # 13m
    cert_p99: 5_640     # 94m
  }.freeze

  # A "no durable write in 15m ⇒ STALLED" rule — the obvious design — would have
  # flagged 79% of healthy desks (193/243), and STILL would not have caught the
  # 2026-07-13 wedge, whose failing certs wrote no gate rows at all and whose
  # 28-minute silence is shorter than the healthy median. Silence is simply not
  # evidence of a wedge: agents legitimately think, run 90-minute certs, and wait
  # on the operator. A chip that cries wolf on four of five healthy desks is the
  # same lying gate with its polarity flipped — a frequent lying-RED instead of a
  # rare lying-GREEN — and it would train every reader to ignore it.
  #
  # So we surface the AGE as a fact and let the reader judge. The only verdict we
  # draw is `quiet?`, suppressed while a gate is demonstrably in flight and
  # defaulting to HEALTHY whenever the progress fact is unknown. It is
  # informational: nothing here reclaims a desk, blocks a move, or deletes
  # anything.
  #
  # THE THRESHOLD IS DERIVED, NOT CHOSEN. It must clear every measured healthy
  # window, and clear the worst of them with room to spare, because THE DATA DOES
  # NOT SUPPORT A CONFIDENT p99: at n=243 the empirical p99 rests on the two or
  # three largest observations in the tail, so 125m is a point estimate with wide
  # error bars — the true p99 could sit materially higher and this corpus could
  # not tell. Parking the threshold ON that estimate would flag healthy desks
  # every time the tail breathed. So we clear the worst measured window by half
  # again (x1.5), an ordinary engineering margin on a noisy tail estimate, and one
  # this feature can afford: quiet is informational, so the cost of being LATE is
  # a chip that appears an hour after it might have, while the cost of being EARLY
  # is the chip crying wolf on healthy work — the one failure this task exists to
  # prevent. Re-measure the corpus and the threshold moves with it; that is the
  # point of deriving it. 3h07m, deliberately not a round number.
  QUIET_SAFETY_FACTOR = 1.5
  PROGRESS_QUIET_SECONDS = (MEASURED_SILENCE_SECONDS.values.max * QUIET_SAFETY_FACTOR).ceil # 11_250s

  # Seconds since the task's last durable artifact. nil (unknown) when the caller
  # cannot determine one — an unknown progress fact must never read as trouble.
  def self.progress_age(last_progress_at, now: Time.now)
    at = last_progress_at.is_a?(Time) ? last_progress_at : parse_time(last_progress_at)
    return nil if at.nil?

    age = now - at
    age.negative? ? 0 : age.round
  end

  # "28m" / "3.1h" — ONE rendering of the progress age, for every surface that
  # states it: the board card, the task page, and the claim gate bin/task prints to
  # a second agent. It lived twice (helper + CLI, copied verbatim) and two
  # renderings of one fact are a drift waiting to happen — the board saying "2h"
  # while the gate says "120m" is a small version of exactly the confusion this
  # module exists to end.
  def self.humanize_age(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60
    return "#{(seconds / 60.0).round}m" if seconds < 3600

    "#{(seconds / 3600.0).round(1)}h"
  end

  # True only when a LIVE lease has gone quiet: the desk is held, we KNOW the
  # progress fact, it is older than `quiet_after`, and no gate is in flight.
  # Every uncertainty resolves to false (healthy) by construction.
  def self.quiet?(claim, last_progress_at:, in_flight: false, now: Time.now, quiet_after: PROGRESS_QUIET_SECONDS)
    return false unless live?(claim, now: now)
    return false if in_flight

    age = progress_age(last_progress_at, now: now)
    return false if age.nil?

    age > quiet_after
  end

  # --- Abandonment, which is NOT silence ------------------------------------
  #
  # `quiet?` above reports. THIS decides, and it is the only thing in this file
  # that can cost a holder its desk — so read the argument before touching it.
  #
  # THE BUG. The lease is renewed by bin/statusline, which paints whether or not
  # an agent is working. So an open terminal renews a build claim forever: on
  # 2026-08-13 a claim ticked 16:05:16Z → 16:06:46Z while three agents stalled
  # behind it, and this machine carries long-lived `claude` processes that have
  # been open for days. A heartbeat proves a TERMINAL IS OPEN. Nothing more.
  #
  # THE OBVIOUS FIX IS THE DANGEROUS ONE. "Renew only on durable task writes"
  # would have judged that same holder dead while it was WRITING TEST FILES INTO
  # ITS DESK (09:40:58 and 09:41:37, both bespoke to the race it was fixing).
  # Board silence is not idleness — an agent thinks, reads, and edits for long
  # stretches without touching the board, and stealing a desk from a worker
  # mid-edit costs the work itself, where a lingering lease only costs waiting.
  # So the two errors are NOT symmetric, and this predicate is deliberately
  # lopsided: EVERY channel must be silent before it says yes, and every unknown
  # resolves to no.
  #
  # THE CHANNELS, and why each is here rather than alone:
  #   desk_touched      — mtimes under the holder's own desk (DeskActivity). The
  #                       signal that actually tracked the truth on 08-13. nil =
  #                       could not tell, which short-circuits to "not abandoned".
  #   gate_in_flight    — a cert writes NOTHING into the desk while it runs, and
  #                       the measured g1_cert p99 is 94 minutes. Without this
  #                       channel a long green cert would look exactly like a
  #                       walked-away terminal.
  #   awaiting_approval — a task parked on the operator (`--approval waiting`) is
  #                       not abandoned; it is blocked on a human, deliberately,
  #                       and its agent is right to be doing nothing.
  #   progress_age      — durable board artifacts. Kept as a channel (never as
  #                       THE criterion) so a holder working through the API
  #                       rather than the filesystem still reads as alive.
  #
  # WHAT THIS IS NOT: it does not reclaim, block, or delete. It only makes the
  # heartbeat DECLINE to renew, after which the ordinary TTL lapses the lease and
  # the ordinary gate lets the next claimant in. A holder that wakes up re-claims
  # on its own next heartbeat, so the mistake this can make is self-healing.

  # Measured desk-edit gaps: 341 samples across 37 real worktree desks on
  # 2026-08-13, taken as the consecutive differences of file mtimes under each
  # desk (pruned of machine churn) after its checkout. The method OVERESTIMATES
  # gaps — a file rewritten five times contributes only its final mtime — which
  # is the conservative direction for an upper bound.
  #
  # THE TAIL OF THIS CORPUS IS THE BUG ITSELF, which is why it is split. Gaps
  # divide into a working band and an abandoned band (a desk left overnight and
  # picked up the next day), and deriving a threshold from the pooled p99 (6.4h)
  # would be circular: it would learn "abandonment is normal" from abandonment
  # data and ship a gate that never fires.
  #
  # The 1-hour separator between the bands is a JUDGMENT, stated here rather than
  # hidden. Two things make it a defensible one. The bands do not overlap at it:
  # the busiest working gap is 3556s and the quietest abandoned gap is 3895s, a
  # 339-second gutter with no samples in it. And the derivation is stable if you
  # move it — a 2-hour separator yields 7347s, the same posture one band wider.
  MEASURED_DESK_GAP_SECONDS = {
    working_p50: 36,      # 36s   — median gap between edits inside a working desk
    working_p90: 729,     # 12m
    working_p95: 1_182,   # 20m
    working_p99: 2_397,   # 40m
    working_max: 3_556,   # 59m   — the binding number: the quietest working desk
    abandoned_min: 3_895, # 65m   — the busiest abandoned desk
    abandoned_p50: 12_236 # 3.4h  — the typical walked-away desk
  }.freeze

  # Clear the worst measured WORKING gap by half again. The margin is doing real
  # work: n=324 in that band, so its max is a point estimate on a noisy tail, and
  # being EARLY here steals a desk from a live worker while being LATE only makes
  # an abandoned desk linger a while longer. 1h29m, deliberately not a round
  # number — a round threshold reads as chosen, and this one is derived.
  DESK_IDLE_SAFETY_FACTOR = 1.5
  DESK_IDLE_SECONDS = (MEASURED_DESK_GAP_SECONDS[:working_max] * DESK_IDLE_SAFETY_FACTOR).ceil # 5_334

  # True only when EVERY channel is silent past `idle_after`. Any positive signal,
  # and any unknown, returns false (the holder keeps its desk).
  #
  # desk_touched: true / false / nil — DeskActivity.touched_since?(desk, cutoff).
  # progress_age: seconds since the last durable board artifact; nil = none ever.
  def self.abandoned?(desk_touched:, progress_age: nil, gate_in_flight: false,
                      awaiting_approval: false, idle_after: DESK_IDLE_SECONDS)
    # UNKNOWN FIRST, and unconditionally. A desk we could not read (no desk bound
    # to this task, an unreadable root, a walk that ran out of budget) is not a
    # quiet desk — it is no evidence at all, and no evidence never frees a claim.
    return false if desk_touched.nil?
    return false if desk_touched
    return false if gate_in_flight
    return false if awaiting_approval
    return false if !progress_age.nil? && progress_age <= idle_after

    true
  end

  # The claim hash a fresh renewal writes — the holder's identity plus a lease
  # that expires `ttl` from now. Merge this into the devops payload.
  #
  # `prior` (the claim being renewed, optional) guards the one thing a renewal
  # must never do: DOWNGRADE a good nonce to blank. A renewal can run where no
  # nonce resolves — the classic case is the DETACHED status-line heartbeat, whose
  # process reparents away from the `claude`/`codex` ancestor so
  # SessionIdentity.nonce degrades to "". Writing that blank through would erase
  # the per-instance token the two-terminals guard needs on every render. So when
  # the fresh nonce is blank but the SAME session's prior claim already carries
  # one, keep it. A freshly RESOLVED nonce always wins (that is how a blanked
  # claim self-heals); a DIFFERENT session's nonce is never inherited.
  def self.renewed(session:, nonce:, now: Time.now, ttl: DEFAULT_TTL_SECONDS, prior: nil)
    nonce = nonce.to_s
    if nonce.strip.empty? && prior
      prior_session = (prior["claimed_session"] || prior[:claimed_session]).to_s
      prior_nonce = (prior["claim_nonce"] || prior[:claim_nonce]).to_s
      nonce = prior_nonce if prior_session == session.to_s && !prior_nonce.strip.empty?
    end
    {
      "claimed_session"  => session.to_s,
      "claim_nonce"      => nonce,
      "claim_expires_at" => (now + ttl).utc.iso8601
    }
  end

  # Pull just the claim keys out of a devops hash (string OR symbol keyed).
  def self.from_devops(devops)
    devops ||= {}
    CLAIM_KEYS.each_with_object({}) do |key, claim|
      value = devops[key]
      value = devops[key.to_sym] if value.nil? && devops.respond_to?(:key?)
      claim[key] = value
    end
  end

  def self.parse_time(value)
    text = value.to_s.strip
    return nil if text.empty?

    Time.parse(text)
  rescue ArgumentError
    nil
  end
end
