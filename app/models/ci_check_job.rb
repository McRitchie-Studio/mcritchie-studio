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

  # The columns the fold reads: `name` is the check IDENTITY a re-run re-uses;
  # `status` + `conclusion` are the fold input (the GitHub check-runs row shape
  # CheckProgress.from_check_runs consumes); `run_id` + `job_id` are the
  # newest-attempt key (both GitHub ids climb monotonically); `started_at` +
  # `completed_at` are the CLOCK the card meter shows — the run's elapsed time while
  # checks are pending, and its measured duration once they settle. Ordered as pluck
  # returns them.
  PROGRESS_COLUMNS = %i[name status conclusion run_id job_id started_at completed_at].freeze

  # The subset of a folded row CheckProgress consumes — the newest-attempt key
  # (run_id/job_id) is scaffolding for the fold itself, not part of its output.
  PROGRESS_ROW_KEYS = %w[name status conclusion started_at completed_at].freeze

  validates :repo, :job_id, :head_sha, :status, presence: true
  validates :job_id, uniqueness: true

  scope :for_repo, ->(full_name) { where(repo: full_name) }
  scope :for_sha, ->(sha) { where(head_sha: sha) }

  # Push the refreshed CI progress bar to the affected task card + Next Release card
  # whenever a job is upserted, so the board ticks up with no reload. Delegates to
  # the broadcaster, itself wrapped in Studio::Cable.safe_broadcast, so this
  # after_commit can never raise into the ingest job's write (the SEV-1 guard).
  after_commit :broadcast_ci_progress, on: %i[create update]

  # Rank of a lifecycle status, or -1 for anything unknown so it never outranks a
  # real status. Class-level so the job can compare an incoming string against a
  # stored one without instantiating.
  def self.status_rank(status)
    STATUS_ORDER.fetch(status.to_s, -1)
  end

  # A commit's CI jobs as the { "status" =>, "conclusion" =>, "name" => } rows
  # Ci::CheckProgress.from_check_runs folds — one row per CHECK. Empty when no job
  # event has landed for this repo+SHA (the reader then falls back to the API).
  #
  # `workflow_name` SCOPES the fold to a single workflow — load-bearing for a gem
  # repo, whose `main` SHA carries BOTH its own suite (studio-engine's "Engine CI")
  # and the downstream "Consumer CI": folding both would drag the gem's track red on
  # a failing sibling. Nil (the app default) folds every recorded row, correct
  # because an app's release branch runs only `CI`.
  #
  # De-duplicated to the LATEST ATTEMPT per check (see latest_attempt_per_check):
  # a re-run mints new job_ids for the same names on the same SHA, and folding
  # every attempt DOUBLED the operator's live count — the v1.2 reset bug.
  def self.progress_rows(repo, sha, workflow_name = nil)
    scope = for_repo(repo).for_sha(sha)
    scope = scope.where(workflow_name: workflow_name) if workflow_name.present?
    latest_attempt_per_check(scope.pluck(*PROGRESS_COLUMNS))
  end

  # A re-run — GitHub's "re-run all / failed jobs", or a fresh workflow_run on the
  # same head SHA — mints NEW job_ids for the SAME check NAMES, so a SHA's raw rows
  # can hold two-plus attempts at once. Folding them all is the reset/re-run
  # DUPLICATION bug: an 8-check suite re-run once counted 16. Keep only the LATEST
  # attempt of each check — group by check NAME, take the newest by (run_id,
  # job_id). Both GitHub ids climb monotonically, so the re-run's row wins whether
  # it landed under the SAME run (re-run failed → same run_id, higher job_id) or a
  # NEW one (new run_id) — a re-run RESETS the display to the real check total
  # instead of accumulating. A blank name (an older, pre-name row) can't be
  # collapsed with others, so it keys on its own job_id and stays its own check.
  def self.latest_attempt_per_check(rows)
    rows
      .map { |values| PROGRESS_COLUMNS.map(&:to_s).zip(values).to_h }
      .group_by { |row| row["name"].presence || "job:#{row["job_id"]}" }
      .map { |_key, attempts| attempts.max_by { |row| [row["run_id"].to_i, row["job_id"].to_i] } }
      .map { |row| row.slice(*PROGRESS_ROW_KEYS) }
  end

  def terminal?
    status == "completed"
  end

  private

  def broadcast_ci_progress
    DeploymentsBroadcaster.ci_progress(self)
  end
end
