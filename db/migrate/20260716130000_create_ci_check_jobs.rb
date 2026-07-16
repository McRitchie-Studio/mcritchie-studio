# Per-SHA CI check progress, one row per GitHub Actions `workflow_job` — the
# push-driven data source behind the board's LIVE CI progress bars (v1.1 of
# visual-ci-progress-bars). v1 read per-check counts from the GitHub check-runs
# API on render; the `workflow_job` webhook lets us record each job's status as it
# moves (queued -> in_progress -> completed) so the bar ticks up with no reload.
#
# Written only by GithubWorkflowRunIngestJob (the idempotent, monotonic upsert,
# keyed on the immutable job_id). Read by Ci::ProgressReader, which folds a SHA's
# rows into a Ci::CheckProgress and prefers them over the API fallback.
class CreateCiCheckJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :ci_check_jobs do |t|
      t.string :repo, null: false            # owner/repo, e.g. amcritchie/mcritchie-studio
      t.bigint :job_id, null: false          # GitHub workflow_job id — the upsert key
      t.bigint :run_id                        # parent workflow_run id (grouping / debug)
      t.string :head_sha, null: false        # the commit these checks belong to
      t.string :head_branch                   # resolves the affected task / release card
      t.string :workflow_name                 # only "CI" jobs are ingested (see the job)
      t.string :name                          # the check's job name, e.g. "lint"
      t.string :status, null: false          # queued / in_progress / completed
      t.string :conclusion                    # success / failure / … (null while running)
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    # The upsert key — a re-delivery updates the same row, never a duplicate.
    add_index :ci_check_jobs, :job_id, unique: true
    # The fold query: every CI job for a commit (Ci::ProgressReader#live_progress).
    add_index :ci_check_jobs, [:repo, :head_sha]
  end
end
