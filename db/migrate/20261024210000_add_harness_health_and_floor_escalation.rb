# Harness health on the dispatcher row, a harness_degraded floor kind, and the
# floor's escalation to a person (AgentMessages::FloorAlert;
# docs/agents/agents/steffon/sops/agent-dispatcher.md).
#
#   agent_dispatchers.op_ok / gh_ok    the Mac's last bounded `op whoami` and
#                                      GitHub check, carried on the minute ping
#   agent_dispatchers.power_source     "ac" or "battery" from `pmset -g batt`
#   agent_dispatchers.harness_checked_at  when the Mac measured them
#   agent_dispatchers.harness_failing_beats  consecutive measured beats with op
#                                      or gh false; harness_degraded opens at 5
#   agent_mailbox_incidents.episode_id the first incident of a flapping run of
#                                      the same kind (and subject); NULL on that
#                                      first incident itself
#   flap_posted_at / escalated_at / final_recovery_at / final_posted_at
#                                      on an episode's first incident: the one
#                                      Discord "flapping" line, the one escalation
#                                      email, the one recovery email, and the one
#                                      Discord line that closes a flapping episode
class AddHarnessHealthAndFloorEscalation < ActiveRecord::Migration[8.1]
  OLD_KINDS = %w[dispatcher_silent message_waiting db_backup_missing db_backup_sweep_failed
                 submitted_unclaimed change_build_refused].freeze
  NEW_KINDS = (OLD_KINDS + %w[harness_degraded]).freeze
  CONSTRAINT = "agent_mailbox_incidents_kind_known".freeze

  def up
    change_table :agent_dispatchers, bulk: true do |t|
      t.boolean :op_ok
      t.boolean :gh_ok
      t.string :power_source
      t.datetime :harness_checked_at
      t.integer :harness_failing_beats, null: false, default: 0
    end
    change_table :agent_mailbox_incidents, bulk: true do |t|
      t.bigint :episode_id
      t.datetime :flap_posted_at
      t.datetime :escalated_at
      t.datetime :final_recovery_at
      t.datetime :final_posted_at
      t.index :episode_id
    end
    remove_check_constraint :agent_mailbox_incidents, name: CONSTRAINT
    add_check_constraint :agent_mailbox_incidents, kinds_sql(NEW_KINDS), name: CONSTRAINT
  end

  def down
    execute "DELETE FROM agent_mailbox_incidents WHERE kind = 'harness_degraded'"
    remove_check_constraint :agent_mailbox_incidents, name: CONSTRAINT
    add_check_constraint :agent_mailbox_incidents, kinds_sql(OLD_KINDS), name: CONSTRAINT
    change_table :agent_mailbox_incidents, bulk: true do |t|
      t.remove_index :episode_id
      t.remove :episode_id, :flap_posted_at, :escalated_at, :final_recovery_at, :final_posted_at
    end
    change_table :agent_dispatchers, bulk: true do |t|
      t.remove :op_ok, :gh_ok, :power_source, :harness_checked_at, :harness_failing_beats
    end
  end

  private

  def kinds_sql(kinds) = "kind IN (#{kinds.map { |k| "'#{k}'" }.join(', ')})"
end
