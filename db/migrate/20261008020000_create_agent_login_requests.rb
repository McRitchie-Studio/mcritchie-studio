# A request for an admin agent session (docs/agents/system/agent-sessions-design.md,
# section 3). A new table; its foreign key takes a brief lock on agent_sessions.
class CreateAgentLoginRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_login_requests do |t|
      t.string :slug, null: false
      # steffon | xan.
      t.string :soul, null: false
      # The Claude or Codex session that asked, and the only one that may collect.
      t.string :harness_session_id, null: false
      # pending | granted | refused. A lapse is computed from requested_at.
      t.string :status, null: false, default: "pending"
      # SHA-256 of the one-time code and of the requester's collect key.
      t.string :phrase_digest, null: false
      t.string :collect_digest, null: false
      t.integer :code_attempts, null: false, default: 0
      t.string :decided_by
      t.string :refusal_reason
      t.string :agent_session_slug
      t.datetime :requested_at, null: false
      t.datetime :decided_at
      t.datetime :collected_at
      t.timestamps
    end
    add_index :agent_login_requests, :slug, unique: true
    add_index :agent_login_requests, %i[status requested_at]
    add_index :agent_login_requests, :agent_session_slug
    add_foreign_key :agent_login_requests, :agent_sessions, column: :agent_session_slug, primary_key: :slug,
                                                            on_update: :cascade
  end
end
