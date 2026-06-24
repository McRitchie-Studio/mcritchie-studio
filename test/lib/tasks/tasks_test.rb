require "test_helper"
require "rake"

# Unit/integration tier: the `tasks:respace_ranks` cutover rake re-spaces existing
# Task#position into the new 100-gap rank (newest-created on top per stage) and
# guards against clobbering an already-migrated board.
class TasksRespaceRanksRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tasks:respace_ranks")
  end

  def run_rake(force: false)
    Rake::Task["tasks:respace_ranks"].reenable
    ENV["FORCE"] = "1" if force
    out, = capture_io { Rake::Task["tasks:respace_ranks"].invoke }
    out
  ensure
    ENV.delete("FORCE")
  end

  test "tasks:respace_ranks orders each stage by created_at with 100-gaps, newest on top" do
    older  = Task.create!(title: "respace older task here", stage: "reviewed")
    middle = Task.create!(title: "respace middle task here", stage: "reviewed")
    newer  = Task.create!(title: "respace newer task here", stage: "reviewed")
    older.update_column(:created_at, 3.days.ago)
    middle.update_column(:created_at, 2.days.ago)
    newer.update_column(:created_at, 1.day.ago)
    # Simulate legacy dense positions (pre-cutover) via update_column (no callbacks).
    [older, middle, newer].each_with_index { |t, i| t.update_column(:position, i) }

    run_rake(force: true)

    positions = [older, middle, newer].map { |t| t.reload.position }
    assert positions.all? { |p| (p % 100).zero? && p.positive? },
           "every re-spaced position is a positive multiple of 100 (got #{positions.inspect})"
    # Oldest-created gets the lowest rank, newest the highest → newest sorts on top
    # under `position DESC`.
    assert_operator older.position, :<, middle.position
    assert_operator middle.position, :<, newer.position
  end

  test "tasks:respace_ranks is a guarded no-op once the board is 100-aligned" do
    # First pass (forced) puts every task on a 100-boundary.
    run_rake(force: true)
    before = Task.order(:id).pluck(:id, :position).to_h

    # Second pass without FORCE: the board now looks migrated, so the guard skips
    # and no manual reorder would be clobbered.
    out = run_rake
    assert_match(/already on the 100-gap rank/i, out)
    after = Task.order(:id).pluck(:id, :position).to_h
    assert_equal before, after, "guard left every position untouched"
  end
end
