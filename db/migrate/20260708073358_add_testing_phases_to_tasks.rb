# Materialized per-task testing-phase durations (Task::TestingPhases), denormalized
# onto the task row exactly like releases.duration_metrics (Release::DurationCache).
# version defaults to 0 so every existing row reads as stale and self-heals on first
# access until the backfill runs.
class AddTestingPhasesToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :testing_phases, :jsonb, default: {}, null: false
    add_column :tasks, :testing_phases_cached_at, :datetime
    add_column :tasks, :testing_phases_version, :integer, default: 0, null: false
  end
end
