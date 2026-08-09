# GitHub re-runs a workflow under the SAME run_id, bumping `run_attempt`. Storing
# it lets the ingest tell a NEWER attempt's verdict (which must win) from a late
# out-of-order re-delivery of an OLDER one (which must not) — the row is what
# Ci::ReviewGate reads to authorise a merge, so it may never be wrong.
# Nullable + no backfill: rows ingested before this column read nil and are
# treated as attempt 1, which is what they were.
class AddRunAttemptToGithubWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :github_workflow_runs, :run_attempt, :integer
  end
end
