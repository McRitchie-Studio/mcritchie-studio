# frozen_string_literal: true

# The `backend_migration` exclusive lane — "one Dev writes a migration at a
# time" (docs/agents/system/exclusive-lanes.md).
#
# WHY THIS IS A ROW AND NOT AN ADVISORY LOCK. The lane shipped as
# `Task.try_acquire_migration_lane`, a Postgres SESSION advisory lock. Nothing
# could operate it: `bin/task` is an HTTP client against /api/v1 with no
# database connection of its own, and a lock taken inside a web request stays on
# the POOLED connection after the response — released at some later, unrelated
# moment, or handed to a stranger. Advisory locks are also RE-ENTRANT per
# connection, so two acquires served by one pooled connection would BOTH return
# true. That is the one failure a lane may never have: granting twice is worse
# than not existing, because the docs then promise protection nobody has.
#
# So the claim is durable state. One row per lane under a UNIQUE index, taken
# with `with_lock` (SELECT … FOR UPDATE): two simultaneous acquirers serialize
# and exactly one wins. It is the same shape as TaskReviewClaim and
# ReleaseConductorClaim — the house pattern for a lease — and it reuses the same
# pure lease math (lib/claim_lease.rb), so a crashed holder's claim LAPSES
# rather than wedging the lane until someone finds a psql prompt.
#
# Enforcement is cooperative, matching the studio's honor-system posture: the
# lane refuses the second acquirer and the SOP tells that Dev to queue. Nothing
# here blocks a migration file from being written (see the gate finding in the
# PR body).
class MigrationLaneClaim < ApplicationRecord
  include RaceTolerantCreate

  # The acquire verdict: whether THIS instance now holds the lane, the ClaimLease
  # disposition it was in, and the (updated) row for the refusal message.
  Outcome = Struct.new(:acquired, :disposition, :claim, keyword_init: false)

  # A migration is written in one sitting, but that sitting is long: schema
  # design, the migration file, the seed/fixture update, and a test run share the
  # lane. The review lane's 120s TTL suits a claim renewed every ~5s by the
  # status line; this lane has no renewer, so the TTL is the whole working
  # window. Four hours frees a crashed holder the same working day while never
  # yanking the lane out from under live work. `release` is the normal exit — the
  # TTL is the backstop for the holder who never comes back.
  DEFAULT_TTL_SECONDS = 4 * 60 * 60

  validates :lane, presence: true, uniqueness: true

  before_validation { self.lane = lane.to_s.strip.presence }

  # Try to take (or renew) the lane for this live instance.
  #
  # Unclaimed / expired / same-instance → acquired. A DIFFERENT live instance
  # holds it → refused, and the caller queues. Note the refusal is keyed on the
  # HOLDING INSTANCE, not on the task: the same task approached from a second
  # session is still a second Dev, and the lane exists to stop exactly that.
  # Atomic under a row lock. Returns an Outcome.
  def self.acquire(task_slug: nil, session:, nonce:, label: nil, agent: nil, lane: Task::MIGRATION_LANE,
                   now: Time.current, ttl: DEFAULT_TTL_SECONDS)
    row = claim_row(lane)
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
          # On a genuine change-of-hands (unclaimed/expired) the new holder's
          # identity replaces the old one wholesale; only a same-instance renewal
          # inherits what it already wrote. Inheriting a PRIOR holder's task or
          # label would make `status` name the wrong Dev.
          task_slug:    task_slug.to_s.strip.presence || (disposition == :same_instance ? row.task_slug : nil),
          holder_label: label.to_s.strip.presence || (disposition == :same_instance ? row.holder_label : nil),
          holder_agent: agent.to_s.strip.presence || (disposition == :same_instance ? row.holder_agent : nil),
          acquired_at:  (disposition == :same_instance ? (row.acquired_at || now) : now)
        )
        outcome = Outcome.new(true, disposition, row)
      end
    end
    outcome
  end

  # Drop the lane — but ONLY the instance that holds it may release it, so a
  # queued Dev can never release the holder out from under a live migration.
  # Returns true when released, false otherwise.
  #
  # A release by a non-holder (including a task that never acquired) is a
  # harmless false, NOT an error: the SOP's belt-and-suspenders release on
  # shipped/blocked/archived runs whether or not the lane was ever taken.
  def self.release(session:, nonce:, lane: Task::MIGRATION_LANE, now: Time.current)
    row = find_by(lane: lane.to_s.strip)
    return false unless row

    released = false
    row.with_lock do
      next unless ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now) == :same_instance

      row.update!(claimed_session: nil, claim_nonce: nil, claim_expires_at: nil,
                  task_slug: nil, holder_label: nil, holder_agent: nil, acquired_at: nil)
      released = true
    end
    released
  end

  # The holder descriptor for the lane (the CLI `status` read), or nil when no
  # claim row exists yet — which reads as "nobody holds it", the same as a row
  # whose lease lapsed.
  def self.status_for(lane = Task::MIGRATION_LANE, now: Time.current)
    find_by(lane: lane.to_s.strip)&.holder_info(now: now)
  end

  # Find (or create) the singleton row for a lane, tolerating the create race —
  # two first-acquirers collide on the lane's uniqueness; the loser re-reads the
  # winner's row and then contends for it under the row lock like everyone else.
  # RaceTolerantCreate covers BOTH halves of that window (the validator's
  # RecordInvalid as well as the index's RecordNotUnique) — see the concern for
  # why rescuing only the latter let a losing first-acquirer RAISE out of
  # `acquire` instead of being refused.
  def self.claim_row(lane)
    find_or_create_tolerating_race!(lane: lane.to_s.strip)
  end

  # The ClaimLease-shaped view of this row (string keys, ISO8601 expiry) so the
  # pure lease math judges it exactly as it judges a review or build claim.
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
    ClaimLease.heartbeat_age(claim_hash, now: now, ttl: DEFAULT_TTL_SECONDS)
  end

  # The holder descriptor the CLI refusal message + the status read render.
  # `live` is the load-bearing field: a row can exist with a lapsed lease, and
  # that must read as FREE, not as held.
  def holder_info(now: Time.current)
    {
      "lane"          => lane,
      "task_slug"     => task_slug,
      "session"       => claimed_session,
      "agent"         => holder_agent,
      "label"         => holder_label,
      "acquired_at"   => acquired_at&.utc&.iso8601,
      "expires_at"    => claim_expires_at&.utc&.iso8601,
      "heartbeat_age" => heartbeat_age(now: now),
      "live"          => live?(now: now)
    }
  end
end
