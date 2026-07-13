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
