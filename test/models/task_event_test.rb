require "test_helper"

class TaskEventTest < ActiveSupport::TestCase
  test "creating a task records a genesis event with no from-stage" do
    task = Task.create!(title: "Genesis event task", stage: "designed")

    event = task.task_events.chronological.first
    assert_not_nil event
    assert_nil event.from_stage
    assert_equal "designed", event.to_stage
    assert_nil event.seconds_in_from
    assert_equal "Created", event.from_label
  end

  test "every stage change appends exactly one event with from and to" do
    task = tasks(:new_task) # designed, no events yet (fixtures skip callbacks)

    assert_difference -> { task.task_events.count }, 1 do
      task.build!
    end

    event = task.task_events.chronological.last
    assert_equal "designed", event.from_stage
    assert_equal "building", event.to_stage
    assert_equal "Building", event.to_label
  end

  test "a non-stage update does not append an event" do
    task = tasks(:in_progress_task)

    assert_no_difference -> { task.task_events.count } do
      task.update!(priority: 2)
    end
  end

  test "seconds_in_from measures wall-clock time spent in the prior stage" do
    task = nil
    travel_to Time.zone.local(2026, 6, 22, 9, 0, 0) do
      task = Task.create!(title: "Duration timeline task", stage: "designed")
    end
    travel_to Time.zone.local(2026, 6, 22, 10, 0, 0) do
      task.update!(stage: "building")
    end
    travel_to Time.zone.local(2026, 6, 22, 12, 30, 0) do
      task.update!(stage: "submitted")
    end

    events = task.task_events.chronological.to_a
    building  = events.find { |e| e.to_stage == "building" }
    submitted = events.find { |e| e.to_stage == "submitted" }

    assert_equal "designed", building.from_stage
    assert_equal 3600, building.seconds_in_from   # 1h in designed
    assert_equal "building", submitted.from_stage
    assert_equal 9000, submitted.seconds_in_from   # 2.5h in building
  end

  test "agent-supplied per-transition usage rides in via Current" do
    Current.task_event_source = "cli"
    Current.task_event_model = "claude-opus-4-8"
    Current.task_event_tokens_in = 1200
    Current.task_event_tokens_out = 3400
    Current.task_event_cost = "0.42".to_d

    task = tasks(:new_task)
    task.build!

    event = task.task_events.chronological.last
    assert_equal "cli", event.source
    assert_equal "claude-opus-4-8", event.model
    assert_equal 4600, event.tokens_total
    assert_equal "0.42".to_d, event.cost
    assert event.usage?
  ensure
    Current.reset
  end

  test "deterministic-only transitions record no usage" do
    task = tasks(:new_task)
    task.build!

    event = task.task_events.chronological.last
    assert_nil event.model
    assert_nil event.cost
    assert_not event.usage?
  end

  test "events are destroyed with their task" do
    task = Task.create!(title: "Disposable timeline task", stage: "designed")
    assert task.task_events.exists?

    assert_difference -> { TaskEvent.count }, -task.task_events.count do
      task.destroy!
    end
  end
end
