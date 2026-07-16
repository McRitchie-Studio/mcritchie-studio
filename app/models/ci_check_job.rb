# frozen_string_literal: true

# One GitHub Actions `workflow_job` — a single CI check for a commit — recorded so
# the board's CI progress bar can tick up LIVE as each job settles, instead of
# polling the check-runs API on render (v1.1 of visual-ci-progress-bars). Written
# only by GithubWorkflowRunIngestJob (the idempotent, monotonic upsert keyed on the
# immutable job_id); read by Ci::ProgressReader, which folds a SHA's rows into a
# Ci::CheckProgress and prefers them over the render-time API fallback.
#
# This is the per-job sibling of GithubWorkflowRun (the per-RUN row): a run's ~8
# jobs each get a row here, so a `completed`+`success` job is one passing check.
class CiCheckJob < ApplicationRecord
  # A job's lifecycle, in progress order. The ingest job uses these ranks to advance
  # a job monotonically and never regress it (a late `in_progress` re-delivery must
  # not clobber a `completed` row) — mirrors GithubWorkflowRun::STATUS_ORDER.
  STATUS_ORDER = { "queued" => 0, "in_progress" => 1, "completed" => 2 }.freeze

  # The CI status keys Ci::CheckProgress folds from — status + conclusion, the exact
  # shape CheckProgress.from_check_runs consumes (the GitHub check-runs row shape).
  PROGRESS_KEYS = %i[status conclusion].freeze

  validates :repo, :job_id, :head_sha, :status, presence: true
  validates :job_id, uniqueness: true

  scope :for_repo, ->(full_name) { where(repo: full_name) }
  scope :for_sha, ->(sha) { where(head_sha: sha) }

  # Push the refreshed CI progress bar to the affected task card + Next Release card
  # whenever a job is upserted, so the board ticks up with no reload. Delegates to
  # the broadcaster, itself wrapped in Studio::Cable.safe_broadcast, so this
  # after_commit can never raise into the ingest job's write (the SEV-1 guard,
  # mirroring GithubWorkflowRun#broadcast_actions_panel).
  after_commit :broadcast_ci_progress, on: %i[create update]

  # Rank of a lifecycle status, or -1 for anything unknown so it never outranks a
  # real status. Class-level so the job can compare an incoming string against a
  # stored one without instantiating.
  def self.status_rank(status)
    STATUS_ORDER.fetch(status.to_s, -1)
  end

  # A commit's CI jobs as the { "status" =>, "conclusion" => } rows
  # Ci::CheckProgress.from_check_runs folds — one row per check. Empty when no
  # job event has landed for this repo+SHA (the reader then falls back to the API).
  def self.progress_rows(repo, sha)
    for_repo(repo).for_sha(sha)
      .pluck(*PROGRESS_KEYS)
      .map { |status, conclusion| { "status" => status, "conclusion" => conclusion } }
  end

  def terminal?
    status == "completed"
  end

  private

  def broadcast_ci_progress
    DeploymentsBroadcaster.ci_progress(self)
  end
end
