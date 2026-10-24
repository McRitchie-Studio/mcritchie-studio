# Warm sessions per domain (docs/agents/system/agent-message-loop.md, "Warm
# sessions"; plan: Phase 7 of .agents/epics/domain-agents.md).
#
# agent_domain_sessions: one row per domain, holding the board lease on that
# domain's live Claude session (holder, lease_expires_at, heartbeat_at), the
# session's head (claude_session_id), how far it has run (turns,
# context_tokens), its generation (bumped by each consolidation), and the
# transcript checkpoint (an Active Storage attachment named `checkpoint`, so
# no column) with checkpointed_at. Not `agent_sessions`: that name is the
# builder sessions' (app/models/agent_session.rb).
#
# agent_domain_summaries: what a consolidation wrote. The next session of the
# domain starts fresh from the newest one.
#
# agent_dispatchers.role / standby_domains: a dispatcher registered as the
# standby for a list of domains (AgentDispatcher.set_role!). Every existing
# row is a primary, so nothing changes until someone registers a standby.
#
# agent_message_events (kind, created_at): the usage meter's capped count
# (AgentUsage.capped_count) reads usage_capped events by month.
class CreateAgentDomainSessions < ActiveRecord::Migration[8.1]
  ROLES = %w[primary standby].freeze

  def change
    create_table :agent_domain_sessions do |t|
      t.string :domain, null: false
      t.string :holder
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.string :claude_session_id
      t.integer :generation, null: false, default: 1
      t.integer :turns, null: false, default: 0
      t.bigint :context_tokens, null: false, default: 0
      t.datetime :checkpointed_at
      t.integer :checkpoint_bytes
      t.datetime :handback_requested_at
      t.string :handback_requested_by
      t.timestamps
    end
    add_index :agent_domain_sessions, :domain, unique: true

    create_table :agent_domain_summaries do |t|
      t.string :domain, null: false
      t.integer :generation, null: false
      t.text :text, null: false
      t.string :source_session_id
      t.integer :turns_covered, null: false, default: 0
      t.bigint :context_tokens
      t.string :written_by
      t.datetime :created_at, null: false
    end
    add_index :agent_domain_summaries, [ :domain, :generation ], unique: true

    add_column :agent_dispatchers, :role, :string, null: false, default: "primary"
    add_column :agent_dispatchers, :standby_domains, :jsonb, null: false, default: []
    add_check_constraint :agent_dispatchers, "role IN (#{ROLES.map { |r| "'#{r}'" }.join(', ')})",
                         name: "agent_dispatchers_role_known"

    add_index :agent_message_events, [ :kind, :created_at ]
  end
end
