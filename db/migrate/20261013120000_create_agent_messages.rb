# The agent mailbox, phase 1 (docs/agents/system/agent-message-loop.md): inbound
# messages from a channel (Discord today) routed to a soul, claimed by a worker
# under a lease, answered once. Named channel-neutral on purpose: `channel` +
# `external_id` is the provider's id, so a second channel adds rows, not tables.
class CreateAgentMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_messages do |t|
      t.string :channel, null: false
      t.string :external_id, null: false
      t.string :guild_id
      t.string :channel_ref, null: false
      t.string :thread_key, null: false
      t.string :author_ref
      t.string :author_name
      t.text :content, null: false, default: ""
      t.jsonb :mentions, null: false, default: {}
      t.string :soul_slug
      t.string :routed_by
      t.string :status, null: false, default: "received"
      t.string :claimed_by
      t.datetime :claimed_at
      t.datetime :lease_expires_at
      t.integer :attempts, null: false, default: 0
      t.text :response_text
      t.text :action_summary
      t.string :reply_nonce
      t.string :reply_external_id
      t.datetime :reply_posted_at
      t.datetime :completed_at
      t.datetime :sent_at
      t.timestamps
    end
    add_index :agent_messages, [:channel, :external_id], unique: true
    add_index :agent_messages, [:soul_slug, :status, :id]
    add_index :agent_messages, [:thread_key, :id]
    add_index :agent_messages, :status

    create_table :agent_message_events do |t|
      t.references :agent_message, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :actor
      t.jsonb :detail, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :agent_message_events, [:agent_message_id, :id]

    # One read position per polled source (a Discord channel id), so a poll
    # resumes where the last one stopped instead of re-reading history.
    create_table :agent_message_cursors do |t|
      t.string :channel, null: false
      t.string :source_ref, null: false
      t.string :cursor
      t.datetime :polled_at
      t.text :last_error
      t.timestamps
    end
    add_index :agent_message_cursors, [:channel, :source_ref], unique: true
  end
end
