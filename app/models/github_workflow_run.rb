# A cached GitHub Actions run, one row per Actions `workflow_run`, keyed on the
# immutable run_id. Written only by GithubWorkflowRunIngestJob (which owns the
# idempotent, monotonic upsert). This model stays thin: it is the read surface
# the board queries for CI status, plus the canonical status ordering.
class GithubWorkflowRun < ApplicationRecord
  # GitHub's workflow_run lifecycle, in the order it PROGRESSES. The ingest job
  # uses these ranks to advance a run monotonically and never regress it (a late
  # `in_progress` re-delivery must not clobber a `completed` row).
  STATUS_ORDER = { "queued" => 0, "in_progress" => 1, "completed" => 2 }.freeze

  # The deploy pipeline reads left to right — CI proves the code, QA Deploy stages
  # it, Production Deploy ships it. These are the `name:` fields of the three
  # .github/workflows files; the /deployments Actions panel leads with them in this
  # order and sorts any other workflow after them, alphabetically.
  CANONICAL_WORKFLOWS = ["CI", "QA Deploy", "Production Deploy"].freeze

  # The GitHub webhook events that mean "a deployment is waiting for a human". A
  # standard environment with required reviewers fires `deployment_review`; a
  # custom (GitHub App) protection rule fires `deployment_protection_rule`. Both
  # carry `environment` + `workflow_run`, so the ingest job handles them together.
  PENDING_REVIEW_EVENTS = %w[deployment_review deployment_protection_rule].freeze

  validates :repo, :run_id, :status, presence: true
  validates :run_id, uniqueness: true

  scope :for_sha, ->(sha) { where(head_sha: sha) }
  scope :for_repo, ->(full_name) { where(repo: full_name) }
  # Runs blocked on an operator approval — the read surface for the pending-approval
  # panel state and its Discord nudge.
  scope :pending_approval, -> { where.not(pending_environment: nil) }

  # Push the refreshed Actions panel to every live /deployments viewer whenever a
  # run is upserted. Delegates to the broadcaster, itself wrapped in
  # Studio::Cable.safe_broadcast, so this after_commit can never raise into the
  # ingest job's write (the SEV-1 guard, mirroring Release#broadcast_release_modules).
  after_commit :broadcast_actions_panel, on: %i[create update]

  # Rank of a lifecycle status, or -1 for anything unknown so it never outranks a
  # real status. Class-level so the job can compare an incoming string against a
  # stored one without instantiating.
  def self.status_rank(status)
    STATUS_ORDER.fetch(status.to_s, -1)
  end

  # The most-recent run per workflow_name — the read surface the Actions panel
  # renders. One query, no N+1: Postgres DISTINCT ON keeps the newest row per
  # workflow (newest by run_started_at, falling back to created_at, then run_id).
  # Runs with a blank workflow_name are skipped (no label for the row). The result
  # is ordered by CANONICAL_WORKFLOWS, with any extra workflow trailing alphabetically.
  def self.latest_per_workflow
    runs = where.not(workflow_name: nil)
           .select("DISTINCT ON (workflow_name) *")
           .order(Arel.sql("workflow_name, run_started_at DESC NULLS LAST, created_at DESC, run_id DESC"))
           .to_a
    rank = CANONICAL_WORKFLOWS.each_with_index.to_h
    runs.sort_by { |run| [rank.fetch(run.workflow_name, CANONICAL_WORKFLOWS.size), run.workflow_name.to_s] }
  end

  def terminal?
    status == "completed"
  end

  # True while this run is blocked on an operator approving a deployment to a
  # protected environment. Orthogonal to `status` — the run is mid-flight
  # (in_progress) and simultaneously waiting on a human.
  def pending_approval?
    pending_environment.present?
  end

  private

  def broadcast_actions_panel
    DeploymentsBroadcaster.github_actions
  end
end
