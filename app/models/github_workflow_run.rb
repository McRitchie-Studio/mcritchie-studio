# A cached GitHub Actions run, one row per Actions `workflow_run`, keyed on the
# immutable run_id. Written only by GithubWorkflowRunIngestJob (which owns the
# idempotent, monotonic upsert). This model stays thin: it is the read surface
# the board queries for CI status, plus the canonical status ordering.
class GithubWorkflowRun < ApplicationRecord
  # GitHub's workflow_run lifecycle, in the order it PROGRESSES. The ingest job
  # uses these ranks to advance a run monotonically and never regress it (a late
  # `in_progress` re-delivery must not clobber a `completed` row).
  STATUS_ORDER = { "queued" => 0, "in_progress" => 1, "completed" => 2 }.freeze

  # The one workflow whose per-job progress feeds the board's CI bars — the single
  # source both the ingest (which CiCheckJob rows to record) and Ci::ProgressReader
  # (which run's SHA to fold) key on.
  CI_WORKFLOW = "CI"

  # The CI-SUITE workflows whose per-job progress feeds the board's release CI
  # meters: the app repos' `CI` PLUS each gem repo's own suite workflow
  # (studio-engine's "Engine CI"). The ingest records CiCheckJob rows ONLY for
  # these — a gem's downstream "Consumer CI" runs on the same `main` SHA but is NOT
  # a surfaced track, so it is never recorded. Ci::ProgressReader additionally
  # SCOPES each track's fold to its own workflow, so even a sibling workflow that
  # slips in never blends into a gem's track. Kept in sync with
  # Ci::ProgressReader::GEM_CI_WORKFLOWS by
  # test/models/ci_progress_workflow_consistency_test.rb.
  CI_PROGRESS_WORKFLOWS = [CI_WORKFLOW, "Engine CI"].freeze

  validates :repo, :run_id, :status, presence: true
  validates :run_id, uniqueness: true

  scope :for_sha, ->(sha) { where(head_sha: sha) }
  scope :for_repo, ->(full_name) { where(repo: full_name) }

  # Rank of a lifecycle status, or -1 for anything unknown so it never outranks a
  # real status. Class-level so the job can compare an incoming string against a
  # stored one without instantiating.
  def self.status_rank(status)
    STATUS_ORDER.fetch(status.to_s, -1)
  end

  def terminal?
    status == "completed"
  end
end
