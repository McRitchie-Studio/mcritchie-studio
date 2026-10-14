# bin/dispatcher's heartbeat to the board (docs/agents/agents/steffon/sops/agent-dispatcher.md):
# one row per dispatcher process, upserted by its minute ping, and the incidents
# the floor alert (AgentDispatcherAlertJob) opens and closes, so each outage is
# announced once and its recovery once.
class CreateAgentDispatchers < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_dispatchers do |t|
      t.string :worker_id, null: false
      t.string :host
      t.jsonb :souls, null: false, default: []
      t.integer :running, null: false, default: 0
      t.integer :capacity
      t.datetime :paused_until
      t.string :pause_reason
      t.string :state
      t.string :version
      t.datetime :started_at
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :agent_dispatchers, :worker_id, unique: true
    add_index :agent_dispatchers, :last_seen_at

    create_table :agent_mailbox_incidents do |t|
      t.string :kind, null: false
      t.jsonb :detail, null: false, default: {}
      t.datetime :opened_at, null: false
      t.datetime :resolved_at
      t.datetime :alert_posted_at
      t.datetime :recovery_posted_at
      t.timestamps
    end
    add_check_constraint :agent_mailbox_incidents, "kind IN ('dispatcher_silent', 'message_waiting')",
                         name: "agent_mailbox_incidents_kind_known"
    # At most one OPEN incident per kind: the dedupe the alert relies on.
    add_index :agent_mailbox_incidents, :kind, unique: true, where: "resolved_at IS NULL",
                                              name: "index_agent_mailbox_incidents_one_open_per_kind"
  end
end
