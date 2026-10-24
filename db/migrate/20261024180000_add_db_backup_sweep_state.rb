# The nightly database-backup sweep (DbBackupSweepJob, Steffon's agent job;
# docs/agents/agents/steffon/sops/db-restore-drill.md):
#
#   apps.backup_status   what the last sweep saw of the app's latest Heroku
#                        Postgres backup (finished_at, size, state), which the
#                        07:00 daily app report reads for its backup line
#   two incident kinds   db_backup_missing and db_backup_sweep_failed, announced
#                        once per incident by the floor alert the dispatcher uses
class AddDbBackupSweepState < ActiveRecord::Migration[8.1]
  OLD_KINDS = %w[dispatcher_silent message_waiting].freeze
  NEW_KINDS = (OLD_KINDS + %w[db_backup_missing db_backup_sweep_failed]).freeze
  CONSTRAINT = "agent_mailbox_incidents_kind_known".freeze

  def up
    add_column :apps, :backup_status, :jsonb, null: false, default: {}
    remove_check_constraint :agent_mailbox_incidents, name: CONSTRAINT
    add_check_constraint :agent_mailbox_incidents, kinds_sql(NEW_KINDS), name: CONSTRAINT
  end

  def down
    execute "DELETE FROM agent_mailbox_incidents WHERE kind IN ('db_backup_missing', 'db_backup_sweep_failed')"
    remove_check_constraint :agent_mailbox_incidents, name: CONSTRAINT
    add_check_constraint :agent_mailbox_incidents, kinds_sql(OLD_KINDS), name: CONSTRAINT
    remove_column :apps, :backup_status
  end

  private

  def kinds_sql(kinds) = "kind IN (#{kinds.map { |k| "'#{k}'" }.join(', ')})"
end
