# DevOps v2 — the board's cache of GitHub Actions `workflow_run` state, fed by
# GithubWorkflowRunIngestJob off the webhook receiver so agents READ CI status
# here instead of polling `gh`. One row per Actions run, keyed on the immutable
# run_id (unique index — the webhook is at-least-once). head_sha is indexed for
# later Release/Task linking.
class CreateGithubWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :github_workflow_runs do |t|
      t.string   :repo,           null: false   # repository.full_name, e.g. "mcritchie/mcritchie-studio"
      t.string   :workflow_name                 # workflow_run.name, e.g. "CI"
      t.bigint   :run_id,         null: false   # workflow_run.id — GitHub's stable run identifier
      t.string   :head_sha                      # commit under test (Release/Task join key)
      t.string   :head_branch
      t.string   :status,         null: false   # queued | in_progress | completed
      t.string   :conclusion                    # success | failure | ... (nil until completed)
      t.string   :html_url
      t.datetime :run_started_at
      t.timestamps
    end

    add_index :github_workflow_runs, :run_id, unique: true
    add_index :github_workflow_runs, :head_sha
  end
end
