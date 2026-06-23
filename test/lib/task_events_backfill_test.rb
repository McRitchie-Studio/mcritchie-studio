require "test_helper"
require "rake"

# Coverage for lib/tasks/task_events.rake — the acceptance criterion (synthesize
# a TaskEvent timeline for legacy tasks from their stage-timestamp columns) that
# shipped without a test. Runs the task in-process against the test DB, inside
# the fixture transaction, so it rolls back cleanly.
class TaskEventsBackfillTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_events:backfill")
  end

  # reenable so the same process can invoke it more than once (idempotency check).
  def run_backfill
    task = Rake::Task["task_events:backfill"]
    task.reenable
    capture_io { task.invoke } # swallow the summary puts
  end

  # [integration] a legacy task with no events gets a system, backfilled, usage-
  # free timeline reconstructed from its stage timestamps.
  test "backfill synthesizes a system event timeline from the stage timestamps" do
    t0 = 3.days.ago.change(usec: 0)
    task = Task.create!(title: "backfill timestamp task", stage: "shipped")
    # Stamp a known historical timeline, then strip the genesis event so the row
    # looks like pre-TaskEvent legacy data the backfill is meant to reconstruct.
    task.update_columns(
      created_at: t0,
      started_at: t0 + 1.hour,
      submitted_at: t0 + 2.hours,
      reviewed_at: t0 + 3.hours,
      assembled_at: t0 + 4.hours,
      completed_at: t0 + 5.hours
    )
    task.task_events.delete_all

    run_backfill

    events = task.task_events.chronological.to_a
    assert_equal 6, events.size
    assert_equal [nil, "designed", "building", "submitted", "reviewed", "assembled"], events.map(&:from_stage)
    assert_equal %w[designed building submitted reviewed assembled shipped], events.map(&:to_stage)
    assert(events.all? { |e| e.source == "system" }, "every synthesized row is source=system")
    assert(events.all?(&:backfilled?), "every synthesized row is flagged backfilled=true")
    assert(events.none?(&:usage?), "synthesized rows carry no usage attribution")
    assert(events.all? { |e| e.actor.nil? }, "synthesized rows carry no actor")
    assert_equal 3600, events[1].seconds_in_from # the gap between the first two points
  end

  # [integration] a task that already has events is skipped — re-running the
  # backfill is a no-op for it.
  test "backfill is idempotent for tasks that already have events" do
    task = Task.create!(title: "backfill idempotent task", stage: "building")
    assert_operator task.task_events.count, :>=, 1, "create! writes a genesis event"

    assert_no_difference -> { task.task_events.count } do
      run_backfill
    end
    assert_no_difference -> { task.task_events.count } do
      run_backfill # a second pass still adds nothing
    end
  end
end
