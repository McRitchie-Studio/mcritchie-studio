# The agent mailbox's memory and run record (docs/agents/system/agent-message-loop.md):
#
#   - an index for the per-person ledger: one soul's exchanges with one author in
#     one channel, read newest first (AgentMessages::ThreadLedger);
#   - what the answering Claude run reported: its session id, the folder it ran
#     from (so `claude --resume` can find the transcript), its reasoning when the
#     transcript carries any, and a few envelope numbers;
#   - agent_user_notes: notes about a sender, keyed by (channel, author_ref). This
#     task only reads them; writing them is a later task.
class AddThreadContextToAgentMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_messages, :claude_session_id, :string
    add_column :agent_messages, :claude_cwd, :string
    add_column :agent_messages, :reasoning, :text
    add_column :agent_messages, :run_meta, :jsonb, default: {}, null: false

    add_index :agent_messages, [ :soul_slug, :channel, :channel_ref, :author_ref, :created_at ],
              name: "index_agent_messages_on_ledger"

    create_table :agent_user_notes do |t|
      t.string :channel, null: false
      t.string :author_ref, null: false
      t.string :display_name
      t.text :notes, null: false, default: ""
      t.timestamps
    end
    add_index :agent_user_notes, [ :channel, :author_ref ], unique: true
  end
end
