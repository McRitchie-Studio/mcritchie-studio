# frozen_string_literal: true

# An ARMED MERGE — one reviewer's already-formed, already-recorded merge-ready
# verdict, written down so it can finish executing after that reviewer's process
# is gone.
#
# THE PROBLEM IT SOLVES (measured seven times on the night of 2026-08-10/11): a
# reviewer completes its review, records a correct merge-ready verdict, waits on a
# CI lane, and its process ends before it can merge. Nothing was wrong with the
# review. The DECISION was already durable — a scout-report activity on the task —
# and only the EXECUTION was lost. A human was the safety net all seven times; one
# reviewer stopped with 3 of 4 lanes green and the fourth settled eighty seconds
# later. At forty concurrent tasks nobody is awake to be that safety net.
#
# WHAT IT IS NOT. This row never FORMS a verdict, and neither does anything that
# reads it. It records an instruction a reviewer already gave — "merge THIS pr at
# THIS sha, on the authority of THIS recorded verdict" — and the executor either
# carries it out unchanged or refuses. Keep that line bright: any future code here
# that weighs a diff, judges CI beyond green/not-green, or decides mergeability on
# its own has turned an errand-runner into an unsupervised reviewer.
#
# THE PIN is `head_sha`. A verdict describes a TREE, not a branch name: if the head
# moved after the review, the recorded decision simply does not apply to what is
# there now, and the action refuses rather than merging code no one read. The pin
# is enforced three times over — against the CI we hold, against the live PR head,
# and by GitHub itself via the merge API's `sha` parameter.
#
# EVERY OTHER GUARD FAILS CLOSED TOO: only a settled GREEN acts (red, pending,
# cancelled and ABSENT check-runs all do nothing — "no checks reported" is the
# signature of a CONFLICTING PR, not a pass); an action past `expires_at` is
# dropped rather than executed late; and an action with no authorising verdict is
# never created in the first place.
class ReviewPendingAction < ApplicationRecord
  # The only action this table knows how to execute today. Named (rather than
  # assumed) so a second action type is an explicit addition, not a silent reuse.
  MERGE_TO_ACCEPTED = "merge_to_accepted"
  ACTIONS = [MERGE_TO_ACCEPTED].freeze

  PENDING  = "pending"
  EXECUTED = "executed"
  EXPIRED  = "expired"
  REFUSED  = "refused"
  DISARMED = "disarmed"
  STATES = [PENDING, EXECUTED, EXPIRED, REFUSED, DISARMED].freeze
  TERMINAL_STATES = (STATES - [PENDING]).freeze

  # The recorded scout-report outcome that AUTHORISES a merge. Deliberately just
  # the one: `merge-ready` is the reviewer saying "no blockers, merge it". The
  # sibling outcomes are not authorisations — `wait-for-ci` is a deferral,
  # `request-changes` a block, `conductor-review` an escalation to a human — and
  # reading any of them as consent would be inventing a verdict.
  AUTHORISING_VERDICT = "merge-ready"

  # How long an armed merge stays executable. Long enough to cover a slow CI
  # lane (the failure this exists for settled in eighty seconds) and a queued
  # re-run, short enough that an action never executes against a world that has
  # moved on while everyone slept. Past this the action is dropped, not run.
  DEFAULT_TTL = 6.hours

  # Slug-based FK, the convention everywhere in this schema.
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true, inverse_of: false

  # Normalize the two columns the webhook trigger JOINs on. A settled CI run
  # names its repo as a full name ("McRitchie-Studio/mcritchie-studio") and its
  # sha in lowercase hex; an action armed with a bare repo slug or an uppercased
  # sha would simply never be found by its own trigger — invisible, not refused.
  before_validation do
    self.repo = self.class.normalize_repo(repo)
    self.head_sha = head_sha.to_s.strip.downcase.presence
  end

  def self.normalize_repo(value, default_owner: Ci::ReviewGate::DEFAULT_OWNER)
    repo = value.to_s.strip
    return repo if repo.empty? || repo.include?("/")

    "#{default_owner}/#{repo}"
  end

  validates :task_slug, presence: true
  validates :repo, presence: true
  validates :head_sha, presence: true
  validates :pr_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :verdict, presence: true
  validates :expires_at, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :state, inclusion: { in: STATES }

  scope :pending, -> { where(state: PENDING) }
  scope :for_head, ->(repo, sha) { where(repo: repo.to_s, head_sha: sha.to_s) }
  scope :recent_first, -> { order(created_at: :desc) }

  # Arm a merge for a task — the ONE creation path, so the authorisation check can
  # never be bypassed by a caller that builds the row itself.
  #
  # Raises Unauthorised when no `merge-ready` scout report exists on the task. That
  # is the "never invent a verdict" rule made structural: with no recorded decision
  # there is nothing to execute, and arming would be the machine deciding to merge.
  #
  # A re-arm (same task, new head after a zap) SUPERSEDES the live action rather
  # than stacking a second merge order beside it.
  class Unauthorised < StandardError; end

  def self.arm!(task:, repo:, pr_number:, head_sha:, pr_url: nil, base_branch: "accepted",
                merge_method: "merge", authorized_by: nil, now: Time.current, ttl: DEFAULT_TTL)
    verdict = authorising_verdict_for(task)
    unless verdict
      raise Unauthorised,
            "no recorded #{AUTHORISING_VERDICT} scout report on #{task.slug} — nothing to execute"
    end

    transaction do
      pending.where(task_slug: task.slug).find_each do |live|
        live.update!(state: DISARMED, outcome_reason: "superseded by a re-arm at #{head_sha}")
      end

      create!(
        task_slug:           task.slug,
        action:              MERGE_TO_ACCEPTED,
        repo:                repo.to_s,
        pr_number:           pr_number.to_i,
        pr_url:              pr_url.presence,
        base_branch:         base_branch.presence || "accepted",
        merge_method:        merge_method.presence || "merge",
        head_sha:            head_sha.to_s.strip,
        verdict:             AUTHORISING_VERDICT,
        verdict_activity_id: verdict.id,
        verdict_recorded_at: verdict.created_at,
        authorized_by:       authorized_by.presence || verdict.agent_slug.presence,
        state:               PENDING,
        expires_at:          now + ttl
      )
    end
  end

  # The task's most recent `merge-ready` scout report — the recorded decision an
  # armed merge executes. nil when the reviewer never reached that verdict.
  def self.authorising_verdict_for(task)
    return nil unless task

    Activity.for_task(task.slug)
            .where("metadata ->> 'kind' = ?", "scout_report")
            .where("metadata ->> 'outcome' = ?", AUTHORISING_VERDICT)
            .order(created_at: :desc, id: :desc)
            .first
  end

  # THE WEBHOOK TRIGGER. A CI run settling names exactly one repo + head_sha, and
  # that pair selects precisely the actions pinned to that tree — so the pin does
  # double duty as the lookup key, and a settled run on any unrelated branch costs
  # one indexed miss. Called from GithubWorkflowRunIngestJob after every ingest.
  def self.trigger_for_head(repo:, head_sha:)
    repo = normalize_repo(repo)
    head_sha = head_sha.to_s.strip.downcase
    return 0 if repo.blank? || head_sha.blank?

    ids = pending.for_head(repo, head_sha).pluck(:id)
    ids.each { |id| ReviewPendingActionExecutionJob.perform_later(id) }
    ids.size
  end

  def pending?
    state == PENDING
  end

  def expired?(now: Time.current)
    expires_at.present? && expires_at <= now
  end

  # Does the authorising verdict still exist? Re-checked at execution time, not
  # only at arm time: a scout report deleted or superseded between the two is a
  # decision withdrawn, and a withdrawn decision must not still execute.
  def verdict_recorded?
    return false if verdict_activity_id.blank?

    Activity.where(id: verdict_activity_id).exists?
  end

  # "McRitchie-Studio/mcritchie-studio" — the API path segment. The column already
  # stores the full name; this normalises a bare slug arriving from an older caller.
  def repo_nwo(default_owner: Ci::ReviewGate::DEFAULT_OWNER)
    value = repo.to_s.strip
    return value if value.include?("/")

    "#{default_owner}/#{value}"
  end

  def settle!(state:, reason: nil, merge_sha: nil, now: Time.current)
    update!(
      state:          state,
      outcome_reason: reason.presence,
      merge_sha:      merge_sha.presence,
      executed_at:    (state == EXECUTED ? now : executed_at)
    )
  end

  def record_attempt!(now: Time.current)
    update!(attempts: attempts.to_i + 1, last_attempted_at: now)
  end
end
