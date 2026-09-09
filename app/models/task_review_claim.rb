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
  include RaceTolerantCreate

  # The acquire verdict: whether THIS instance now holds the review, the ClaimLease
  # disposition it was in, and the (updated) row for the skip/holder message.
  Outcome = Struct.new(:acquired, :disposition, :claim, keyword_init: false)

  validates :task_slug, presence: true, uniqueness: true

  before_validation { self.task_slug = task_slug.to_s.strip.presence }

  # Try to take (or renew) the review for this live instance. Unclaimed / expired /
  # same-instance → acquired; a DIFFERENT live instance holds it → not acquired
  # (the caller skips this task and moves to the next). Atomic under a row lock.
  # Returns an Outcome.
  def self.acquire(task_slug:, session:, nonce:, label: nil, reviewer: nil, now: Time.current,
                   ttl: ClaimLease::REVIEW_TTL_SECONDS)
    row = claim_row(task_slug)
    # THE SECOND LINE AGAINST SELF-REVIEW. `bin/reviewer-select` is the gate that
    # keeps a builder out of the reviewer seats — but a gate at SELECTION time only
    # helps when selection is the path taken, and it isn't always: a hand-spawned
    # reviewer, a resumed session, or the server-side `claim_next_review` pop all
    # reach the review through the CLAIM. Claiming is the one act every review path
    # performs, so the rule is re-asserted here, where it cannot be walked around.
    #
    # It fires only when BOTH facts are known and equal. A claim carrying no
    # reviewer slug is not a known self-review, and refusing those would wedge the
    # review lane rather than protect it — the fail-closed-on-an-absent-fact half
    # belongs to reviewer-select, which has somewhere to send the caller.
    return Outcome.new(false, :self_review, row) if self_review?(task_slug, reviewer)

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
          holder_agent:     reviewer.to_s.strip.presence || (disposition == :same_instance ? row.holder_agent : nil),
          # keep the original acquired_at across a same-instance renewal; stamp it
          # fresh only when the review genuinely changes hands.
          acquired_at:      (disposition == :same_instance ? (row.acquired_at || now) : now)
        )
        # THE BOARD FACE RIDES THE CLAIM. Claiming IS the atomic "I am reviewing this
        # now" act every review path already performs (`bin/task review-claim acquire`
        # and the server-side `claim_next_review` pop both funnel here), so recording
        # the review intent HERE makes the crew seat a property of REVIEWING rather
        # than of one launcher remembering to call `bin/reviewer-select`. A review
        # spawned off the orchestrator path — a hand-spawn, a resumed reviewer, a
        # future autopilot sweeper — used to run completely invisible: agents
        # reviewed, reported, and merged while the card showed dashed empty seats.
        #
        # Inside the lock, so the seat and the lease can never disagree. The write is
        # idempotent (Task#record_intent_event returns the existing open intent for
        # the same pair) and self-guarding (it no-ops unless the task is `submitted`),
        # so renewals never stack rows. Best-effort: a telemetry write must never
        # break the mutual-exclusion gate the pipeline depends on.
        # `requires_new` makes the isolation STRUCTURAL rather than accidental: the
        # intent write gets its own savepoint, so a failure there rolls back only
        # itself and can never take the claim's compare-and-set with it. Today
        # `task_events` carries no unique index, FK, or check constraint, so no
        # DB-level raise is reachable and the rescue below suffices — but the review
        # lane's mutual exclusion is too load-bearing to rest on that staying true.
        ActiveRecord::Base.transaction(requires_new: true) { record_review_intent(row.task_slug, reviewer) }
        outcome = Outcome.new(true, disposition, row)
      end
    end
    outcome
  end

  # True when this claim would put a soul on the review of a PR that soul AUTHORED —
  # the one thing reviewer selection exists to prevent. Both sides must resolve: a
  # blank reviewer or an unstamped task is not a known conflict (see .acquire).
  # Any lookup failure answers false, so a telemetry-grade read can never wedge the
  # review lane; reviewer-select remains the gate that refuses on the UNKNOWN.
  #
  # Asked over the whole AUTHOR SET, not just `built_by`. This is the second line
  # behind reviewer-select, and it inherited the same single-slug blind spot: a task
  # can have several authors (a session limit kills a builder mid-work and another
  # soul finishes it), and `built_by` names only the current one. On 2026-08-30
  # agent-flag-silently-drops read built_by=steffon while ALEX had written every test
  # on the diff — so an Alex review claim would have passed this check too, and the
  # backstop would have backed nothing up.
  def self.self_review?(task_slug, reviewer)
    slug = reviewer.to_s.strip
    return false if slug.empty?

    task = Task.find_by(slug: task_slug.to_s.strip)
    return false if task.nil?

    ([task.devops_built_by] + task.devops_builders).map { |s| s.to_s.strip }.include?(slug)
  rescue StandardError => e
    Rails.logger.warn("[review-claim] self-review check failed for #{task_slug}: #{e.class}: #{e.message}")
    false
  end

  # The intent write behind the crew seat. TaskEvent broadcasts on create-commit, so
  # the board paints the reviewer live — no refresh, no polling.
  def self.record_review_intent(task_slug, reviewer)
    slug = reviewer.to_s.strip
    return if slug.empty?

    task = Task.find_by(slug: task_slug)
    return unless task

    task.record_intent_event(to_stage: "reviewed", reviewers: [{ "slug" => slug, "weight" => "primary" }])
  rescue StandardError => e
    Rails.logger.warn("[review-claim] intent record failed for #{task_slug}: #{e.class}: #{e.message}")
    nil
  end

  # The renewal verdict. FOUR STATES, and they are deliberately not collapsed:
  #
  #   :renewed       — a LIVE lease this instance holds, pushed out by one TTL
  #   :reacquired    — this instance's OWN lease had lapsed and nobody else had taken
  #                    it, so the renewal re-took it. The lease is healthy again, but
  #                    there was a WINDOW in which it was free, and the caller has to
  #                    be told: a racing reviewer could have popped the task in it.
  #   :held_by_other — a DIFFERENT live instance holds it (or holds an unverifiable
  #                    lease). Nothing was written.
  #   :no_lease      — there is nothing of ours to renew: no claim row, an unclaimed
  #                    row, or a LAPSED lease belonging to somebody else. Nothing was
  #                    written.
  #
  # `renewed?` is the two-state question every old boolean caller was really asking;
  # it exists so a caller that only needs "did the heartbeat land" cannot accidentally
  # read the truthiness of the struct itself and get `true` for a refusal.
  Renewal = Struct.new(:state, :claim) do
    def renewed? = %i[renewed reacquired].include?(state)
    def reacquired? = state == :reacquired
  end

  # Extend the lease — but ONLY for the instance that already holds it (renew never
  # steals). Returns a Renewal; this is the renewer's path AND the hand-run
  # `bin/task review-claim renew` path.
  #
  # THIS RETURNED A BARE BOOLEAN, AND THE `false` WENT NOWHERE (renew-exits-zero-renewing).
  # The controller turned every false into a bodiless 204 and the CLI threw the
  # response away entirely, so `bin/task review-claim renew` exited 0 while renewing
  # NOTHING. Measured 2026-09-08: a reviewer ran the documented renew loop every 60s
  # against the 120s TTL for ~31 minutes, every call exited 0 with zero stderr, and the
  # lease was FREE for nearly the whole window with its heartbeat frozen at
  # acquisition. That is the no-duplicate-review guarantee failing silently — for that
  # window a second reviewer could have popped the same PR. Three distinct failures
  # answering identically as success is the defect; hence four states, and hence the
  # caller CANNOT get its answer from truthiness alone.
  #
  # RE-ACQUIRING OUR OWN LAPSE IS NOT A STEAL, and it is the difference between a
  # renewer that heals and one that quietly stops. A lapse whose lease is still ours
  # (a slow beat, a slept laptop, a throttled board) used to answer "not renewed", the
  # renewer read that as `:lease_lost` and EXITED — ending renewal for a review that
  # was still being written. The compare-and-set is what keeps this honest: the moment
  # another instance holds a live lease, `evaluate` says :held_by_other and we write
  # nothing. We only ever re-take a lease nobody else wants.
  def self.renew(task_slug:, session:, nonce:, now: Time.current, ttl: ClaimLease::REVIEW_TTL_SECONDS)
    row = find_by(task_slug: task_slug.to_s.strip)
    return Renewal.new(:no_lease, nil) unless row

    outcome = nil
    row.with_lock do
      disposition = ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now)
      mine = ClaimLease.same_instance?(row.claim_hash, session: session, nonce: nonce)

      outcome =
        case disposition
        when :same_instance
          row.update!(claim_expires_at: now + ttl)
          Renewal.new(:renewed, row)
        when :expired
          # Ours to heal, or somebody else's lapsed lease — which is not "held", but is
          # equally not a lease of ours to renew.
          next_state_for_lapse(row, mine, now, ttl)
        when :corrupt
          # An expiry we cannot parse is "we could not check", never "they are gone" —
          # the same posture ClaimLease.live? takes. Ours heals by rewriting a parseable
          # lease; anyone else's is treated as possibly-live and refused.
          mine ? reacquire(row, now, ttl) : Renewal.new(:held_by_other, row)
        when :held_by_other
          Renewal.new(:held_by_other, row)
        else # :unclaimed — a row exists but nobody holds it
          Renewal.new(:no_lease, row)
        end
    end
    outcome
  end

  def self.next_state_for_lapse(row, mine, now, ttl)
    mine ? reacquire(row, now, ttl) : Renewal.new(:no_lease, row)
  end

  def self.reacquire(row, now, ttl)
    row.update!(claim_expires_at: now + ttl)
    Renewal.new(:reacquired, row)
  end
  private_class_method :next_state_for_lapse, :reacquire

  # The release verdict, the mirror of Renewal above and for the same reason: a bare
  # boolean collapsed three different situations into one silence.
  #
  #   :released        — a LIVE lease this instance held, dropped
  #   :released_lapsed — this instance's OWN lease was not renewable (it had lapsed,
  #                      or its expiry was unreadable) and was dropped anyway. The
  #                      row is clean, but the lease was FREE for a window and the
  #                      caller has to be told, exactly as `renew` says on :reacquired
  #   :held_by_other   — a DIFFERENT live instance holds it. Nothing was written, and
  #                      there is somebody to ASK
  #   :no_lease        — nothing of ours to drop: no claim row, an unclaimed one, or
  #                      somebody else's lapsed lease. Nothing was written
  Release = Struct.new(:state, :claim) do
    def released? = %i[released released_lapsed].include?(state)
    def lapsed? = state == :released_lapsed
  end

  # Drop the lease — but ONLY the instance that holds it may release it, so a racing
  # reviewer can never release the holder out from under a live review. Returns a
  # Release. A clean review-end release frees the task immediately rather than waiting
  # out the TTL, so the next pr-review session can pick it up.
  #
  # RELEASING OUR OWN LAPSED LEASE IS NOT A STEAL, and refusing to used to be the last
  # place this file still read a lapse as a stranger. `evaluate` answers :expired
  # BEFORE it compares identity — right for CLAIMING, where a lapsed lease is free to
  # anyone — so the holder of a lease that outran its TTL asked to release it, was
  # told "nothing released", and left a stale row behind. That cost 120s once. Against
  # ClaimLease::REVIEW_TTL_SECONDS it would strand the task for over three hours,
  # which is precisely the review that most needs to hand its task back: the long one.
  # The compare-and-set keeps it honest — the moment another instance holds a live
  # lease, `evaluate` says :held_by_other and we write nothing.
  def self.release(task_slug:, session:, nonce:, now: Time.current)
    row = find_by(task_slug: task_slug.to_s.strip)
    return Release.new(:no_lease, nil) unless row

    outcome = nil
    row.with_lock do
      disposition = ClaimLease.evaluate(row.claim_hash, session: session, nonce: nonce, now: now)
      mine = ClaimLease.same_instance?(row.claim_hash, session: session, nonce: nonce)

      outcome =
        case disposition
        when :same_instance     then drop(row, :released)
        when :expired           then mine ? drop(row, :released_lapsed) : Release.new(:no_lease, row)
        # An expiry we cannot parse is "we could not check", never "they are gone" —
        # ours is dropped (a garbled lease of our own is ours to clear), anyone else's
        # is treated as possibly-live and refused. The same posture ClaimLease.live?
        # and .renew take.
        when :corrupt           then mine ? drop(row, :released_lapsed) : Release.new(:held_by_other, row)
        when :held_by_other     then Release.new(:held_by_other, row)
        else                         Release.new(:no_lease, row) # :unclaimed
        end
    end
    outcome
  end

  def self.drop(row, state)
    row.update!(claimed_session: nil, claim_nonce: nil, claim_expires_at: nil, holder_label: nil, acquired_at: nil)
    Release.new(state, row)
  end
  private_class_method :drop

  # The holder descriptor for one task (the CLI `status <slug>` read), or nil when no
  # claim row exists yet.
  def self.status_for(task_slug, now: Time.current)
    find_by(task_slug: task_slug.to_s.strip)&.holder_info(now: now)
  end

  # Find (or create) the singleton row for a task, tolerating the create race — two
  # first-acquirers collide on the task_slug's uniqueness; the loser re-reads the
  # winner's row. RaceTolerantCreate covers BOTH halves of that window (the
  # validator's RecordInvalid as well as the index's RecordNotUnique).
  def self.claim_row(task_slug)
    find_or_create_tolerating_race!(task_slug: task_slug.to_s.strip)
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

  # Seconds since the holder's last heartbeat, derived as `expiry - TTL`. It MUST be
  # handed this lane's TTL: the default is the 120s build-claim one, and reading a
  # review lease through it reports every freshly renewed claim as ~3h stale — a lie
  # the skip message and the status read would both print. MigrationLaneClaim passes
  # its own for the same reason.
  def heartbeat_age(now: Time.current)
    ClaimLease.heartbeat_age(claim_hash, now: now, ttl: ClaimLease::REVIEW_TTL_SECONDS)
  end

  # The holder descriptor the CLI skip message + the status read render.
  #
  # `agent` is the reviewing SOUL, and it is here because a refusal has to name
  # somebody to ASK. bin/ship's held-task refusal routes a live review to "ask them
  # to release" rather than to `--steal`, and "ask them" is useless without a them:
  # the row has carried `holder_agent` since the crew seat rode the claim, and it
  # simply was not published. `label` is the session's mascot, which paints a card
  # but does not name a reviewer.
  def holder_info(now: Time.current)
    {
      "task_slug"     => task_slug,
      "session"       => claimed_session,
      "label"         => holder_label,
      "agent"         => holder_agent,
      "acquired_at"   => acquired_at&.utc&.iso8601,
      "expires_at"    => claim_expires_at&.utc&.iso8601,
      "heartbeat_age" => heartbeat_age(now: now),
      "live"          => live?(now: now)
    }
  end
end
