# DevOps v2 (v1.1) — surface the operator-approval gate on prod deploys. When a
# run reaches an environment with required reviewers, GitHub delivers a
# `deployment_review` / `deployment_protection_rule` event; the ingest job stamps
# the awaiting environment here so /deployments can show a "pending approval" row
# with an Approve button. Orthogonal to `status` (queued/in_progress/completed) —
# a run is "waiting on a human" while mid-flight, so this never touches the
# monotonic status ladder. Cleared when the review resolves or the run completes.
class AddPendingReviewToGithubWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :github_workflow_runs, :pending_environment, :string # env awaiting review, e.g. "production"; nil = not pending
    add_column :github_workflow_runs, :pending_since, :datetime      # when it entered pending — drives the "waiting Xh" display

    # Partial index: the panel only ever asks "which runs are pending?", a tiny slice.
    add_index :github_workflow_runs, :pending_environment,
              where: "pending_environment IS NOT NULL",
              name: "index_github_workflow_runs_on_pending_environment"
  end
end
