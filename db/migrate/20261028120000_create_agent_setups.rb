# Pending manual setup for an agent (task pending-agents-page; epic
# .agents/epics/agent-onboarding.md): the steps only Alex McRitchie's hands can
# do, such as creating a Discord bot in the Developer Portal, shown as a
# checklist card at /agents/pending.
#
# One row per agent per kind per target (a Discord bot whose token installs on
# mcritchie-studio, later a Gmail delegation or a wallet). Its steps are their
# own rows so each records who did it and when. `details` holds only PUBLIC
# values (the bot name, the application id, the 1Password ids that build the
# item's deep link, the guild, the permission bits); no secret is ever stored.
#
# One LIVE setup per (agent, kind, target): a rotation closes the old row and
# opens a new one.
class CreateAgentSetups < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_setups do |t|
      t.string :agent_slug, null: false
      t.string :kind, null: false
      t.string :target, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :details, null: false, default: {}
      t.text :status_reason
      t.string :opened_by, null: false
      t.string :submitted_by
      t.datetime :submitted_at
      t.string :verified_by
      t.datetime :verified_at
      t.datetime :ready_at
      t.string :closed_by
      t.datetime :closed_at
      t.timestamps
    end
    add_foreign_key :agent_setups, :agents, column: :agent_slug, primary_key: :slug, on_update: :cascade
    add_index :agent_setups, %i[agent_slug kind target], unique: true, where: "closed_at IS NULL",
                                                         name: "index_agent_setups_one_live_per_target"
    add_index :agent_setups, :status
    add_check_constraint :agent_setups,
                         "status IN ('pending', 'checking', 'verifying', 'needs_attention', 'ready', 'closed')",
                         name: "agent_setups_status_known"
    add_check_constraint :agent_setups, "kind IN ('discord_bot')", name: "agent_setups_kind_known"

    create_table :agent_setup_steps do |t|
      t.references :agent_setup, null: false, foreign_key: { on_delete: :cascade }
      t.string :key, null: false
      t.integer :position, null: false
      t.string :done_by
      t.datetime :done_at
      t.timestamps
    end
    add_index :agent_setup_steps, %i[agent_setup_id key], unique: true
  end
end
