# The /dreams heat map counts `dream_fired` actions per dream (`bin/dream fired`
# writes them with the dream's slug in event_slug). agent_actions is the busiest
# write path on the board, so the index is partial, covers only those rows, and is
# built concurrently, outside a transaction, so no capture write waits on it.
class IndexAgentActionsDreamFired < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :agent_actions, [ :event_slug, :occurred_at ],
              where: "kind = 'dream_fired'", name: "index_agent_actions_on_dream_fired",
              algorithm: :concurrently, if_not_exists: true
  end
end
