# Per-card incidents on the floor alert (AgentMessages::FloorAlert;
# docs/agents/agents/steffon/sops/agent-dispatcher.md):
#
#   subject                the task slug a per-card incident names, or NULL for
#                          the floor-wide kinds, which keep one open row per kind
#   submitted_unclaimed    a submitted card with a green DoR and no review claim
#                          for 30 minutes
#   change_build_refused   the build launcher could not start a chat-sourced
#                          change card (bin/task begin refused); the card stays designed
#
# The dedupe stays the table: one open row per kind for a floor-wide incident, and
# one open row per (kind, subject) for a per-card one.
class AddSubjectToAgentMailboxIncidents < ActiveRecord::Migration[8.1]
  OLD_KINDS = %w[dispatcher_silent message_waiting db_backup_missing db_backup_sweep_failed].freeze
  NEW_KINDS = (OLD_KINDS + %w[submitted_unclaimed change_build_refused]).freeze
  CONSTRAINT = "agent_mailbox_incidents_kind_known".freeze
  PER_KIND = "index_agent_mailbox_incidents_one_open_per_kind".freeze
  PER_SUBJECT = "index_agent_mailbox_incidents_one_open_per_subject".freeze

  def up
    add_column :agent_mailbox_incidents, :subject, :string
    remove_index :agent_mailbox_incidents, name: PER_KIND
    add_index :agent_mailbox_incidents, :kind, unique: true, where: "resolved_at IS NULL AND subject IS NULL", name: PER_KIND
    add_index :agent_mailbox_incidents, %i[kind subject], unique: true, where: "resolved_at IS NULL AND subject IS NOT NULL",
                                                          name: PER_SUBJECT
    remove_check_constraint :agent_mailbox_incidents, name: CONSTRAINT
    add_check_constraint :agent_mailbox_incidents, kinds_sql(NEW_KINDS), name: CONSTRAINT
  end

  def down
    execute "DELETE FROM agent_mailbox_incidents WHERE subject IS NOT NULL OR kind IN ('submitted_unclaimed', 'change_build_refused')"
    remove_check_constraint :agent_mailbox_incidents, name: CONSTRAINT
    add_check_constraint :agent_mailbox_incidents, kinds_sql(OLD_KINDS), name: CONSTRAINT
    remove_index :agent_mailbox_incidents, name: PER_SUBJECT
    remove_index :agent_mailbox_incidents, name: PER_KIND
    add_index :agent_mailbox_incidents, :kind, unique: true, where: "resolved_at IS NULL", name: PER_KIND
    remove_column :agent_mailbox_incidents, :subject
  end

  private

  def kinds_sql(kinds) = "kind IN (#{kinds.map { |k| "'#{k}'" }.join(', ')})"
end
