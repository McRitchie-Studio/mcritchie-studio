# Usage capture (tokens/cost) for AtomicActions.
#
# The live-capture hook now reads the assistant turn's `message.usage` from the
# transcript tail (the same seam that resolves the model) and stamps tokens on
# each action. Two schema changes support that:
#
#   * source_turn_uuid — the assistant turn id a row's usage came from. Nullable
#     (pre-usage / board / harness rows carry none) and indexed, because the span
#     + session aggregations DEDUPE by it: one assistant turn can fire N parallel
#     tool calls (N rows sharing that turn's usage), so totals sum over DISTINCT
#     turns rather than per-row.
#   * cost is made NULLABLE — a model with no known rate must record NULL (cost
#     unknown), which is distinct from 0.0 (genuinely free). We never fabricate a
#     price, so the "no rate" case has to be representable as NULL.
class AddSourceTurnUuidToAtomicActions < ActiveRecord::Migration[8.1]
  def up
    add_column :atomic_actions, :source_turn_uuid, :string
    add_index  :atomic_actions, :source_turn_uuid

    change_column_null :atomic_actions, :cost, true
  end

  def down
    remove_index  :atomic_actions, :source_turn_uuid
    remove_column :atomic_actions, :source_turn_uuid

    # Backfill any NULL costs to 0 before restoring the NOT NULL constraint.
    execute "UPDATE atomic_actions SET cost = 0 WHERE cost IS NULL"
    change_column_null :atomic_actions, :cost, false
  end
end
