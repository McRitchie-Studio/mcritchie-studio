# frozen_string_literal: true

# A per-RELEASE conductor claim — the "at most one live conductor per (release, role)"
# gate that replaces the per-ROLE devops SHIFT (DevopsShift) for the two
# release-lifecycle acts: `assembler` (bin/release prepare / qa-release) and
# `deployer` (bin/release ship / production-deploy). The lock used to live on a
# GLOBAL lane (one steffon session, one avi-ship session, ever) — so a stale or
# ghost lease could strand the whole lane for a TTL. Moving it onto the RELEASE
# record, which turns over every release, means a stale claim dies with its release:
# a lock that can never strand a global lane again. This is exactly the move
# TaskReviewClaim made for the review lane (lane → task); here it is lane → (release,
# role).
#
# It reuses the build-claim lease math verbatim (lib/claim_lease.rb): a holder is a
# LIVE INSTANCE (session id + per-process nonce) under a TTL renewed by the run's own
# detached renewer (bin/lib/release_claim_cli.rb). A crashed conductor stops renewing,
# the lease lapses within the TTL, and the (release, role) frees for the next
# conductor — so a careless double-prepare is a graceful stand-down, an interrupted
# ship RESUMES via a same-instance re-acquire, and a dead conductor never wedges a
# release forever.
#
# ACQUIRE is an atomic compare-and-set: one row per (release_slug, role) (composite
# unique index) taken under `with_lock` (SELECT … FOR UPDATE), so two simultaneous
# acquirers serialize and exactly one wins — no two assemblers (or two deployers) on
# one release. The two roles are INDEPENDENT rows, so an assembler and a deployer on
# one release never contend. Enforcement is cooperative (the SOP / bin/release tells
# the loser to stand down), matching the studio's honor-system posture.
class ReleaseConductorClaim < ApplicationRecord
  include RaceTolerantCreate

  # The two release-lifecycle roles. assembler = prepare/qa-release; deployer =
  # ship/production-deploy. A closed set (unlike DevopsShift::LANES) — a claim role
  # is one of exactly these two, so it IS an inclusion validation.
  ROLES = %w[assembler deployer].freeze

  # The reserved "forming" sentinel release_slug. A brand-new `qa-release` promotes
  # `accepted → release` BEFORE any release record exists, so there is no real slug to
  # claim yet — two concurrent fresh sessions would both promote, unguarded. They both
  # `acquire(FORMING_SLUG, :assembler)` first instead: the composite-unique CAS lets
  # exactly one win the forming phase; the loser stands down. Once the real release
  # exists, prepare acquires its real (rel_slug, assembler) claim and HANDS OFF — frees
  # this sentinel — so ownership is continuous across the promote. Double-underscored
  # so no real release slug (kebab-case, board-validated) can ever collide with it.
  FORMING_SLUG = "__forming__"

  # The acquire verdict: whether THIS instance now holds the (release, role), the
  # ClaimLease disposition it was in, and the (updated) row for the stand-down message.
  Outcome = Struct.new(:acquired, :disposition, :claim, keyword_init: false)

  validates :release_slug, presence: true
  validates :role, presence: true, inclusion: { in: ROLES }, uniqueness: { scope: :release_slug }

  before_validation do
    self.release_slug = release_slug.to_s.strip.presence
    self.role = role.to_s.strip.downcase.presence
  end

  # Try to take (or renew) the (release, role) for this live instance. Unclaimed /
  # expired / same-instance → acquired; a DIFFERENT live instance holds it → not
  # acquired (the caller stands down). A same-instance re-acquire is a renew, which is
  # what lets an interrupted ship re-run RESUME instead of stranding. Atomic under a
  # row lock. Returns an Outcome.
  def self.acquire(release_slug:, role:, session:, nonce:, label: nil, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    row = claim_row(release_slug, role)
    outcome = nil
    row.with_lock do
      disposition = ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now)
      if disposition == :held_by_other
        outcome = Outcome.new(false, disposition, row)
      else
        row.update!(
          claimed_session:  session.to_s,
          claim_nonce:      nonce.to_s,
          claim_expires_at: now + ttl,
          # keep the holder's own label; on a genuine change-of-hands (expired/
          # unclaimed) do NOT inherit the PRIOR holder's label — reset to the new
          # holder's label, or nil, exactly as acquired_at resets below.
          holder_label:     label.to_s.strip.presence || (disposition == :same_instance ? row.holder_label : nil),
          # keep the original acquired_at across a same-instance renewal; stamp it
          # fresh only when the claim genuinely changes hands.
          acquired_at:      (disposition == :same_instance ? (row.acquired_at || now) : now)
        )
        outcome = Outcome.new(true, disposition, row)
      end
    end
    outcome
  end

  # OPERATOR OVERRIDE — force the (release, role) to the asking instance regardless of
  # who currently holds it. `acquire` deliberately STANDS DOWN when a DIFFERENT live
  # instance holds the claim (that is the whole anti-double-assembly/ship guarantee), so
  # a stuck or ghost holder strands the (release, role) until its TTL lapses. `reassign`
  # is the operator's escape hatch from that wait: it hands the claim to the session
  # asking — its session + nonce + label BECOME the holder — even over a live holder, so
  # the next `bin/release prepare`/`ship` re-run sees `:same_instance` and RESUMES
  # immediately instead of standing down. It is NEVER on a normal agent path: only the
  # operator-gated controller action reaches it (a plain `acquire` can never steal a
  # live claim, and never will). Atomic under the same row lock as acquire. Returns an
  # Outcome with `disposition: :reassigned` (always acquired).
  def self.reassign(release_slug:, role:, session:, nonce:, label: nil, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    row = claim_row(release_slug, role)
    row.with_lock do
      # A same-instance reassign (the operator re-arming a claim this session already
      # holds) keeps the label it was acquired with unless a new one is given; a genuine
      # change of hands resets acquired_at to now — this instance owns it from now on.
      same = ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now) == :same_instance
      row.update!(
        claimed_session:  session.to_s,
        claim_nonce:      nonce.to_s,
        claim_expires_at: now + ttl,
        holder_label:     label.to_s.strip.presence || (same ? row.holder_label : nil),
        acquired_at:      (same ? (row.acquired_at || now) : now)
      )
    end
    Outcome.new(true, :reassigned, row)
  end

  # Extend the lease — but ONLY for the instance that already holds it (renew never
  # steals). Returns true when renewed, false otherwise. This is the renewer's path.
  def self.renew(release_slug:, role:, session:, nonce:, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    row = find_by(release_slug: release_slug.to_s.strip, role: role.to_s.strip.downcase)
    return false unless row

    renewed = false
    row.with_lock do
      next unless ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now) == :same_instance

      row.update!(claim_expires_at: now + ttl)
      renewed = true
    end
    renewed
  end

  # Drop the lease — but ONLY the instance that holds it may release it. Returns true
  # when released. A clean completion release frees the (release, role) immediately
  # (rather than waiting out the TTL) so the next conductor can pick it up.
  def self.release(release_slug:, role:, session:, nonce:, now: Time.current)
    row = find_by(release_slug: release_slug.to_s.strip, role: role.to_s.strip.downcase)
    return false unless row

    released = false
    row.with_lock do
      next unless ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now) == :same_instance

      row.update!(claimed_session: nil, claim_nonce: nil, claim_expires_at: nil, holder_label: nil, acquired_at: nil)
      released = true
    end
    released
  end

  # The holder descriptor for one (release, role) (the CLI `status` read), or nil when
  # no claim row exists yet.
  def self.status_for(release_slug, role, now: Time.current)
    find_by(release_slug: release_slug.to_s.strip, role: role.to_s.strip.downcase)&.holder_info(now: now)
  end

  # Is ANY claim for `role` currently live (its lease unlapsed)? The CROSS-RELEASE read
  # behind bin/agent-worktree's "is a ship in progress?" reclaim guard: a live `deployer`
  # claim means the fixed-path `_ship`/`_gate` workspaces are pinned by a running
  # `bin/release ship` and must NOT be reclaimed mid-ship (the exclusion the retired `avi`
  # shift used to provide). Iterates the (few) rows for the role so the ClaimLease
  # liveness rules — including the corrupt-expiry "possibly live" fold — apply exactly as
  # everywhere else.
  def self.any_live?(role:, now: Time.current)
    where(role: role.to_s.strip.downcase).any? { |c| c.live?(now: now) }
  end

  # The first live holder's descriptor for `role`, or nil — powers the withhold message.
  def self.live_holder(role:, now: Time.current)
    where(role: role.to_s.strip.downcase).find { |c| c.live?(now: now) }&.holder_info(now: now)
  end

  # Find (or create) the singleton row for a (release, role), tolerating the create
  # race — two first-acquirers collide on the role's scoped uniqueness; the loser
  # re-reads the winner's row. RaceTolerantCreate covers BOTH halves of that window
  # (the validator's RecordInvalid as well as the index's RecordNotUnique); the
  # `inclusion:` failure on `role` keeps raising, as it must.
  def self.claim_row(release_slug, role)
    find_or_create_tolerating_race!(release_slug: release_slug.to_s.strip,
                                    role: role.to_s.strip.downcase)
  end

  # The ClaimLease-shaped view of this row (string keys, ISO8601 expiry) so the pure
  # lease math can judge it exactly as it judges a task's build claim.
  def claim_hash
    {
      "claimed_session"  => claimed_session,
      "claim_nonce"      => claim_nonce,
      "claim_expires_at" => claim_expires_at&.utc&.iso8601
    }
  end

  def live?(now: Time.current)
    ClaimLease.live?(claim_hash, now: now)
  end

  def heartbeat_age(now: Time.current)
    ClaimLease.heartbeat_age(claim_hash, now: now)
  end

  # The holder descriptor the CLI stand-down message + the status read render.
  def holder_info(now: Time.current)
    {
      "release_slug"  => release_slug,
      "role"          => role,
      "session"       => claimed_session,
      "label"         => holder_label,
      "acquired_at"   => acquired_at&.utc&.iso8601,
      "expires_at"    => claim_expires_at&.utc&.iso8601,
      "heartbeat_age" => heartbeat_age(now: now),
      "live"          => live?(now: now)
    }
  end
end
