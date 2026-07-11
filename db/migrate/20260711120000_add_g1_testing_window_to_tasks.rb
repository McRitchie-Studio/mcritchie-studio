# Flat mirror of the g1_cert testing WINDOW onto the task row (GateRun stamps
# these from open!/close! for the g1_cert gate only). Three nullable datetimes —
# never backfilled: an already-certified task simply reads nil until its next
# g1_cert attempt re-stamps them. gate_runs stays the source of truth.
class AddG1TestingWindowToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :g1_testing_started_at, :datetime
    add_column :tasks, :g1_testing_finished_at, :datetime
    add_column :tasks, :g1_failed_at, :datetime
  end
end
