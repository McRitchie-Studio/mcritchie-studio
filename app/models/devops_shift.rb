# frozen_string_literal: true

# A devops SHIFT lease — the "at most one live conductor per lane" gate that keeps
# two same-role devops sessions from colliding (two Avi heartbeats, or an Avi
# heartbeat + a standalone pr-review). A lane is a ROLE/shift key — `avi`, `steffon`,
# `alex` — so same-role acts contend while different-role acts (a review vs a
# qa-release) run side by side.
#
# It reuses the build-claim lease math verbatim (lib/claim_lease.rb): a holder is a
# LIVE INSTANCE (session id + per-process nonce) under a TTL renewed by the
# heartbeat (bin/statusline → bin/devops-shift renew). A crashed conductor stops
# renewing, the lease lapses within the TTL, and the next launch takes over — so a
# careless double-launch is a graceful "already on shift" step-down, and a dead
# shift never wedges the lane forever.
#
# ACQUIRE is an atomic compare-and-set: one row per lane (unique index) taken under
# `with_lock` (SELECT … FOR UPDATE), so two simultaneous acquirers serialize and
# exactly one wins — no split-brain. Enforcement is cooperative (the SOP tells the
# loser to stand down), matching the studio's honor-system posture.
class DevopsShift < ApplicationRecord
  # The known role lanes. NOT an inclusion validation — a new role/lane may appear
  # before this list is updated; the constant is documentation + the CLI's default set.
  LANES = %w[avi steffon alex].freeze

  # The acquire verdict: whether THIS instance now holds the lane, the ClaimLease
  # disposition it was in, and the (updated) row for the holder message.
  Outcome = Struct.new(:acquired, :disposition, :shift, keyword_init: false)

  validates :lane, presence: true, uniqueness: true

  before_validation { self.lane = lane.to_s.strip.downcase.presence }

  # Try to take (or renew) the lane for this live instance. Unclaimed / expired /
  # same-instance → acquired; a DIFFERENT live instance holds it → not acquired.
  # Atomic under a row lock. Returns an Outcome.
  def self.acquire(lane:, session:, nonce:, label: nil, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    row = lane_row(lane)
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
          holder_label:     label.to_s.strip.presence || row.holder_label,
          # keep the original acquired_at across a same-instance renewal; stamp it
          # fresh only when the shift genuinely changes hands.
          acquired_at:      (disposition == :same_instance ? (row.acquired_at || now) : now)
        )
        outcome = Outcome.new(true, disposition, row)
      end
    end
    outcome
  end

  # Extend the lease — but ONLY for the instance that already holds it (renew never
  # steals). Returns true when renewed, false otherwise. This is the heartbeat path.
  def self.renew(lane:, session:, nonce:, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    row = find_by(lane: lane.to_s.strip.downcase)
    return false unless row

    renewed = false
    row.with_lock do
      next unless ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now) == :same_instance

      row.update!(claim_expires_at: now + ttl)
      renewed = true
    end
    renewed
  end

  # Drop the lease — but ONLY the instance that holds it may release it. Returns
  # true when released. A clean session-end release frees the lane immediately
  # (rather than waiting out the TTL).
  def self.release(lane:, session:, nonce:, now: Time.current)
    row = find_by(lane: lane.to_s.strip.downcase)
    return false unless row

    released = false
    row.with_lock do
      next unless ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now) == :same_instance

      row.update!(claimed_session: nil, claim_nonce: nil, claim_expires_at: nil, holder_label: nil, acquired_at: nil)
      released = true
    end
    released
  end

  # Every lane's current holder info (for `bin/devops-shift status` + the dashboard).
  def self.status(now: Time.current)
    order(:lane).map { |shift| shift.holder_info(now: now) }
  end

  # Find (or create) the singleton row for a lane, tolerating the create race — two
  # first-acquirers hit the unique index; the loser re-reads the winner's row.
  def self.lane_row(lane)
    key = lane.to_s.strip.downcase
    find_or_create_by!(lane: key)
  rescue ActiveRecord::RecordNotUnique
    find_by!(lane: key)
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

  # The holder descriptor the CLI step-down message + the status/dashboard read.
  def holder_info(now: Time.current)
    {
      "lane"          => lane,
      "session"       => claimed_session,
      "label"         => holder_label,
      "acquired_at"   => acquired_at&.utc&.iso8601,
      "expires_at"    => claim_expires_at&.utc&.iso8601,
      "heartbeat_age" => heartbeat_age(now: now),
      "live"          => live?(now: now)
    }
  end
end
