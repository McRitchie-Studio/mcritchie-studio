# Promotes four hot `metadata["devops"]` keys to indexed task columns: pr_url,
# branch, approval_status and session_id. Every board read sorts on
# approval_status, and every merged-PR webhook looks a task up by pr_url and
# branch; as jsonb paths both are unindexed scans.
#
# Additive only. The columns are nullable and the migration copies no data, so
# the old code still running during a rolling deploy reads and writes exactly
# what it did. The copy is TaskDevopsColumnsBackfillJob, run by the task's
# post_deploy_cmd (`bin/rails tasks:backfill_devops_columns`) once the new code
# serves; it is idempotent and also repairs any row the old code wrote between
# this migration and the restart. The JSON keys stay written (Task mirrors each
# key into its column on save) until a later migration retires them.
#
# SAFETY: production runs `lock_timeout = 0`, so an ALTER that queued behind a
# long transaction would hold every later board write behind its lock request.
# `SET LOCAL lock_timeout` fails the release phase instead. The tasks table is
# small (2,768 rows, 13 MB on 2026-10-06), so each index builds in milliseconds
# and a plain (non-concurrent) build is the simpler, transactional choice.
class AddDevopsColumnsToTasks < ActiveRecord::Migration[8.1]
  COLUMNS = %i[pr_url branch approval_status session_id].freeze

  def up
    execute "SET LOCAL lock_timeout = '10s'"
    COLUMNS.each do |column|
      add_column :tasks, column, :string unless column_exists?(:tasks, column)
      add_index :tasks, column unless index_exists?(:tasks, column)
    end
  end

  def down
    COLUMNS.each do |column|
      remove_index :tasks, column if index_exists?(:tasks, column)
      remove_column :tasks, column if column_exists?(:tasks, column)
    end
  end
end
