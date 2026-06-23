require "test_helper"
# Object#stub — this file's graceful-degradation test uses it standalone (mock
# isn't required globally; matches the repo's per-file convention), so it must
# not depend on run order.
require "minitest/mock"

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

  test "actor is recorded per-transition from Current" do
    Current.task_event_actor = "avi"
    task = tasks(:new_task)
    task.build!

    assert_equal "avi", task.task_events.chronological.last.actor
  ensure
    Current.reset
  end

  test "a transition does not inherit the claimant session as the actor" do
    # A task claimed at `building` carries devops.session_id. A later transition
    # with no Current actor (model-driven / conductor) must NOT backfill actor
    # from that claimant — doing so mis-attributes the move to the build agent.
    task = Task.create!(title: "claimant actor task", stage: "building",
                        metadata: { "devops" => { "session_id" => "build-sess-1234" } })
    task.update!(stage: "submitted")

    event = task.task_events.chronological.last
    assert_equal "submitted", event.to_stage
    assert_nil event.actor, "model-driven transitions record no actor (no claimant fallback)"
  end

  # --- reviewers recorded on submitted→reviewed (the avatars payload) ---

  test "the submitted→reviewed transition records the two reviewers in event metadata" do
    task = Task.create!(title: "reviewer recording sample task", stage: "submitted",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.review!

    event = task.task_events.chronological.last
    assert_equal "reviewed", event.to_stage
    reviewers = event.metadata["reviewers"]
    assert_equal 2, reviewers.size, "two reviewers recorded for the avatars UI"
    assert_equal %w[heavy light].sort, reviewers.map { |r| r["weight"] }.sort
    assert(reviewers.all? { |r| r["slug"].present? })
    refute_includes reviewers.map { |r| r["slug"] }, "steffon", "the QA owner is never a reviewer"
  end

  test "reviewers ride alongside the primary actor, not replacing it" do
    Current.task_event_actor = "avi"
    task = Task.create!(title: "reviewer actor sample task", stage: "submitted")
    task.review!

    event = task.task_events.chronological.last
    assert_equal "avi", event.actor, "the single actor stays primary"
    assert_equal 2, event.metadata["reviewers"].size
  ensure
    Current.reset
  end

  test "an explicit Current.task_event_reviewers override is recorded verbatim" do
    Current.task_event_reviewers = [{ "slug" => "carl", "weight" => "heavy" },
                                    { "slug" => "alex", "weight" => "light" }]
    task = Task.create!(title: "reviewer override sample task", stage: "submitted")
    task.review!

    reviewers = task.task_events.chronological.last.metadata["reviewers"]
    assert_equal %w[carl alex], reviewers.map { |r| r["slug"] }, "Avi's curated pair wins over auto-select"
  ensure
    Current.reset
  end

  test "non-review transitions record no reviewers (empty event metadata)" do
    task = Task.create!(title: "no reviewer transition task", stage: "designed")
    task.build!  # designed→building
    task.submit! # building→submitted

    task.task_events.chronological.each do |event|
      assert_nil event.metadata["reviewers"], "#{event.from_stage}→#{event.to_stage} must not record reviewers"
    end
  end

  test "a selection error never blocks the stage change (graceful)" do
    task = Task.create!(title: "reviewer graceful sample task", stage: "submitted")
    ReviewerSelector.stub(:select, ->(_t) { raise "boom" }) do
      assert_nothing_raised { task.review! }
    end
    assert_equal "reviewed", task.reload.stage
    assert_nil task.task_events.chronological.last.metadata["reviewers"]
  end

  test "events are destroyed with their task" do
    task = Task.create!(title: "Disposable timeline task", stage: "designed")
    assert task.task_events.exists?

    assert_difference -> { TaskEvent.count }, -task.task_events.count do
      task.destroy!
    end
  end
end
