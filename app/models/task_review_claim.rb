# frozen_string_literal: true

# A per-TASK REVIEW claim — the "at most one live reviewer per submitted task" gate
# that lets MANY pr-review sessions run in parallel: each queries the submitted PR
# tasks NOT already under review (Task.reviewable), claims one atomically, and any
# racing session simply SKIPS it. This is the role-lease (DevopsShift, lane `avi`)
# one level down — lane → task — so the review LANE stops being single-conductor
# while the deploy/QA lanes stay single-conductor.
#
# It reuses the build-claim lease math verbatim (lib/claim_lease.rb): a holder is a
# LIVE INSTANCE (session id + per-process nonce) under a TTL renewed by the review's
# own detached renewer. A crashed reviewer stops renewing, the lease lapses within
# the TTL, and the task frees for the next pr-review session — so a careless double
# review is a graceful skip and a dead review never wedges a task forever.
#
# ACQUIRE is an atomic compare-and-set: one row per task_slug (unique index) taken
# under `with_lock` (SELECT … FOR UPDATE), so two simultaneous acquirers serialize
# and exactly one wins — no two reviewers on one task. Enforcement is cooperative
# (the SOP tells the loser to skip), matching the studio's honor-system posture.
class TaskReviewClaim < ApplicationRecord
  # The acquire verdict: whether THIS instance now holds the review, the ClaimLease
  # disposition it was in, and the (updated) row for the skip/holder message.
  Outcome = Struct.new(:acquired, :disposition, :claim, keyword_init: false)

  validates :task_slug, presence: true, uniqueness: true

  before_validation { self.task_slug = task_slug.to_s.strip.presence }

  # Try to take (or renew) the review for this live instance. Unclaimed / expired /
  # same-instance → acquired; a DIFFERENT live instance holds it → not acquired
  # (the caller skips this task and moves to the next). Atomic under a row lock.
  # Returns an Outcome.
  def self.acquire(task_slug:, session:, nonce:, label: nil, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    row = claim_row(task_slug)
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
          # fresh only when the review genuinely changes hands.
          acquired_at:      (disposition == :same_instance ? (row.acquired_at || now) : now)
        )
        outcome = Outcome.new(true, disposition, row)
      end
    end
    outcome
  end

  # Extend the lease — but ONLY for the instance that already holds it (renew never
  # steals). Returns true when renewed, false otherwise. This is the renewer's path.
  def self.renew(task_slug:, session:, nonce:, now: Time.current, ttl: ClaimLease::DEFAULT_TTL_SECONDS)
    row = find_by(task_slug: task_slug.to_s.strip)
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
  # when released. A clean review-end release frees the task immediately (rather than
  # waiting out the TTL) so the next pr-review session can pick it up.
  def self.release(task_slug:, session:, nonce:, now: Time.current)
    row = find_by(task_slug: task_slug.to_s.strip)
    return false unless row

    released = false
    row.with_lock do
      next unless ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now) == :same_instance

      row.update!(claimed_session: nil, claim_nonce: nil, claim_expires_at: nil, holder_label: nil, acquired_at: nil)
      released = true
    end
    released
  end

  # The holder descriptor for one task (the CLI `status <slug>` read), or nil when no
  # claim row exists yet.
  def self.status_for(task_slug, now: Time.current)
    find_by(task_slug: task_slug.to_s.strip)&.holder_info(now: now)
  end

  # Find (or create) the singleton row for a task, tolerating the create race — two
  # first-acquirers hit the unique index; the loser re-reads the winner's row.
  def self.claim_row(task_slug)
    key = task_slug.to_s.strip
    find_or_create_by!(task_slug: key)
  rescue ActiveRecord::RecordNotUnique
    find_by!(task_slug: key)
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

  # The holder descriptor the CLI skip message + the status read render.
  def holder_info(now: Time.current)
    {
      "task_slug"     => task_slug,
      "session"       => claimed_session,
      "label"         => holder_label,
      "acquired_at"   => acquired_at&.utc&.iso8601,
      "expires_at"    => claim_expires_at&.utc&.iso8601,
      "heartbeat_age" => heartbeat_age(now: now),
      "live"          => live?(now: now)
    }
  end
end
