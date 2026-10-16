# A domain agent's proposal (docs/agents/system/agent-message-loop.md,
# "Proposals and confirm"): the model's answer may end with a PROPOSAL block,
# the board validates it against config/agent_domains.yml and stores it here,
# and the owner's `go`, `no` or `change: …` in the same thread settles it.
#
# One row per accepted proposal. Refused proposals are never stored here; they
# are an event on the message that carried them.
class CreateAgentProposals < ActiveRecord::Migration[8.1]
  STATUSES = %w[proposed confirmed rejected expired executed].freeze
  KINDS = %w[ask operate change].freeze

  def change
    create_table :agent_proposals do |t|
      # The conversation it belongs to, scoped like the THREAD layer
      # (AgentMessages::MemoryBundle#thread_scope): key, channel, guild, channel ref.
      t.string :thread_key, null: false
      t.string :channel, null: false
      t.string :guild_id
      t.string :channel_ref, null: false
      t.string :soul_slug, null: false
      t.references :person, foreign_key: { to_table: :agent_people, on_delete: :nullify }
      # The answer that carried the proposal, and the reply that settled it.
      t.references :source_message, foreign_key: { to_table: :agent_messages, on_delete: :nullify }
      t.references :confirm_message, foreign_key: { to_table: :agent_messages, on_delete: :nullify }
      t.string :kind, null: false
      t.string :capability, null: false
      t.jsonb :params, null: false, default: {}
      t.string :summary
      t.string :status, null: false, default: "proposed"
      t.datetime :expires_at, null: false
      t.datetime :settled_at
      t.string :settled_by
      # What running it produced: the answer text for an ask, the task slug for a
      # change, or the reason it failed.
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end

    add_index :agent_proposals, %i[thread_key status], name: "index_agent_proposals_on_thread_and_status"
    add_check_constraint :agent_proposals, "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(', ')})",
                         name: "agent_proposals_status_known"
    add_check_constraint :agent_proposals, "kind IN (#{KINDS.map { |s| "'#{s}'" }.join(', ')})",
                         name: "agent_proposals_kind_known"
  end
end
