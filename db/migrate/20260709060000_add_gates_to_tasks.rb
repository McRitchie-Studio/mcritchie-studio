# Materialized latest-attempt-per-gate snapshot (Task::GatesProjection), denormalized
# onto the task row exactly like tasks.testing_phases (Task::TestingPhases). version
# defaults to 0 so every existing row reads as stale and self-heals on first access —
# no backfill needed (gate_runs stays the source of truth).
class AddGatesToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :gates, :jsonb, default: {}, null: false
    add_column :tasks, :gates_cached_at, :datetime
    add_column :tasks, :gates_version, :integer, default: 0, null: false
  end
end
