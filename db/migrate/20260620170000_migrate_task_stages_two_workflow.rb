class MigrateTaskStagesTwoWorkflow < ActiveRecord::Migration[7.2]
  # Moves the task board from the legacy 9-stage model to the two-workflow model:
  #
  #   Build:   designed → building → submitted → reviewed
  #   Deploy:  reviewed → assembled → shipped   (reviewed is the seam)
  #   blocked / archived as side + terminal states.
  #
  # Legacy → new mapping:
  #   new, queued        → designed
  #   in_progress        → building
  #   pr_review, qa_review → submitted
  #   prod_ready         → reviewed
  #   done               → shipped
  #   failed             → blocked
  #   archived           → archived
  def up
    add_column :tasks, :submitted_at, :datetime
    add_column :tasks, :reviewed_at,  :datetime
    add_column :tasks, :assembled_at, :datetime
    add_column :tasks, :blocked_at,   :datetime
    add_column :tasks, :blocked_from, :string

    # building reuses started_at, shipped reuses completed_at, archived reuses
    # archived_at — already populated by the legacy timestamps, so no backfill.
    execute "UPDATE tasks SET stage = 'designed' WHERE stage IN ('new', 'queued')"
    execute "UPDATE tasks SET stage = 'building' WHERE stage = 'in_progress'"
    execute "UPDATE tasks SET stage = 'submitted', submitted_at = COALESCE(submitted_at, updated_at) WHERE stage IN ('pr_review', 'qa_review')"
    execute "UPDATE tasks SET stage = 'reviewed', reviewed_at = COALESCE(reviewed_at, updated_at) WHERE stage = 'prod_ready'"
    execute "UPDATE tasks SET stage = 'shipped' WHERE stage = 'done'"
    execute "UPDATE tasks SET stage = 'blocked', blocked_at = COALESCE(failed_at, updated_at) WHERE stage = 'failed'"

    change_column_default :tasks, :stage, from: "new", to: "designed"
  end

  def down
    change_column_default :tasks, :stage, from: "designed", to: "new"

    # Lossy reverse (queued/qa_review were folded in) — restore to the closest
    # legacy stage so the column stays valid under the old model.
    execute "UPDATE tasks SET stage = 'new'         WHERE stage = 'designed'"
    execute "UPDATE tasks SET stage = 'in_progress' WHERE stage = 'building'"
    execute "UPDATE tasks SET stage = 'pr_review'   WHERE stage = 'submitted'"
    execute "UPDATE tasks SET stage = 'prod_ready'  WHERE stage = 'reviewed'"
    execute "UPDATE tasks SET stage = 'prod_ready'  WHERE stage = 'assembled'"
    execute "UPDATE tasks SET stage = 'done'        WHERE stage = 'shipped'"
    execute "UPDATE tasks SET stage = 'failed'      WHERE stage = 'blocked'"

    remove_column :tasks, :submitted_at
    remove_column :tasks, :reviewed_at
    remove_column :tasks, :assembled_at
    remove_column :tasks, :blocked_at
    remove_column :tasks, :blocked_from
  end
end
