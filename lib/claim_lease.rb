# frozen_string_literal: true

require "time"

# The build-stage claim lease — the math that decides who owns a task while it's
# being built. A claim is held by a LIVE INSTANCE, not a bare session id:
#
#   claimed_session  — the agent session that holds the claim (CLAUDE_CODE_SESSION_ID)
#   claim_nonce      — a per-PROCESS-instance token (see bin/task#claim_nonce). Two
#                      terminals running `claude --resume <same id>` share the
#                      session id but are different OS processes → different nonce.
#   claim_expires_at — an ISO8601 TTL lease, renewed by the heartbeat (bin/statusline).
#                      No render for > TTL ⇒ the lease lapses ⇒ the task is reclaimable.
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

    if stored_session == session.to_s && claim["claim_nonce"].to_s == nonce.to_s
      :same_instance
    else
      :held_by_other
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
  # Measured against 14 days of real building sessions (243 live work windows,
  # prod board, 2026-07-13):
  #
  #   max board-write silence inside a HEALTHY window: p50 26m · p90 66m · p99 125m
  #   g1_cert durations:                               p50 2.1m · p90 13m · p99 94m
  #
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
  # draw is `quiet?`, at a deliberately conservative threshold (default 2h, past
  # the measured p99 of both healthy silence AND cert duration), suppressed while
  # a gate is demonstrably in flight, and defaulting to HEALTHY whenever the
  # progress fact is unknown. It is informational: nothing here reclaims a desk,
  # blocks a move, or deletes anything.
  PROGRESS_QUIET_SECONDS = 7200

  # Seconds since the task's last durable artifact. nil (unknown) when the caller
  # cannot determine one — an unknown progress fact must never read as trouble.
  def self.progress_age(last_progress_at, now: Time.now)
    at = last_progress_at.is_a?(Time) ? last_progress_at : parse_time(last_progress_at)
    return nil if at.nil?

    age = now - at
    age.negative? ? 0 : age.round
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

  # The claim hash a fresh renewal writes — the holder's identity plus a lease
  # that expires `ttl` from now. Merge this into the devops payload.
  def self.renewed(session:, nonce:, now: Time.now, ttl: DEFAULT_TTL_SECONDS)
    {
      "claimed_session"  => session.to_s,
      "claim_nonce"      => nonce.to_s,
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
