require "test_helper"

# Task#record_intent_event — the "agentic intent" writer: an agent (or the senior
# pair) STARTING a stage's work, recorded the moment it begins so the board +
# timeline can show who's on it with a live ticker before the transition lands.
class TaskIntentTest < ActiveSupport::TestCase
  REVIEWERS = [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }].freeze

  test "record_intent_event appends an intent FROM the current stage TO the target" do
    task = Task.create!(title: "intent record task", stage: "submitted")
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS, source: "cli")

    assert intent.intent?
    assert_equal "submitted", intent.from_stage
    assert_equal "reviewed", intent.to_stage
    assert_nil intent.seconds_in_from, "an intent carries no duration"
    assert_equal "cli", intent.source
    assert_equal REVIEWERS, intent.metadata["reviewers"]
    assert task.open_intent_for("reviewed").present?
  end

  test "a single-owner intent records its actor (Steffon QA / Avi ship)" do
    task = Task.create!(title: "owner intent task", stage: "reviewed")
    intent = task.record_intent_event(to_stage: "assembled", actor: "steffon")

    assert_equal "steffon", intent.actor
    assert_empty intent.metadata.fetch("reviewers", [])
  end

  test "record_intent_event is idempotent for an identical open intent" do
    task = Task.create!(title: "intent idempotent task", stage: "reviewed")
    first  = task.record_intent_event(to_stage: "assembled", actor: "steffon")
    second = task.record_intent_event(to_stage: "assembled", actor: "steffon")

    assert_equal first.id, second.id, "the same open intent is reused, not stacked"
    assert_equal 1, task.task_events.intents.where(to_stage: "assembled").count
  end

  test "record_intent_event is a no-op once the target stage has landed" do
    task = Task.create!(title: "intent resolved task", stage: "reviewed")
    task.update!(stage: "assembled") # the transition into assembled lands

    assert_nil task.record_intent_event(to_stage: "assembled", actor: "steffon")
    assert_nil task.open_intent_for("assembled")
  end

  test "record_intent_event reopens after rework returns to the source stage" do
    task = Task.create!(title: "intent rework task", stage: "submitted")
    first = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    Current.task_event_reviewers = REVIEWERS
    task.review!
    Current.reset
    assert_nil task.open_intent_for("reviewed"), "the first review transition supersedes the first intent"

    task.block!
    task.build!
    task.submit!
    second = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)

    assert second.present?, "a resubmitted task can start a new review cycle"
    assert_not_equal first.id, second.id
    assert_equal second.id, task.open_intent_for("reviewed").id
  ensure
    Current.reset
  end

  test "record_intent_event ignores a stale intent after direct rework block" do
    task = Task.create!(title: "intent direct block task", stage: "submitted")
    first = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    task.block!
    task.build!
    task.submit!

    assert_nil task.reload.open_intent_for("reviewed"),
               "an intent from the prior submitted cycle is not still open"

    second = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)

    assert second.present?, "the resubmitted cycle can record a fresh review intent"
    assert_not_equal first.id, second.id
    assert_equal second.id, task.reload.open_intent_for("reviewed").id
  end

  test "record_intent_event rejects targets that are not the current next stage" do
    task = Task.create!(title: "intent invalid target task", stage: "shipped")

    assert_nil task.record_intent_event(to_stage: "assembled", actor: "steffon")
    assert_empty task.task_events.intents
  end

  test "open_intent_for resolves once the transition into the target lands" do
    task = Task.create!(title: "intent open task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    assert task.open_intent_for("reviewed").present?, "open while still in submitted"

    Current.task_event_reviewers = REVIEWERS
    task.review!
    assert_nil task.open_intent_for("reviewed"), "a landed →reviewed transition supersedes the intent"
  ensure
    Current.reset
  end

  test "an intent recorded mid-stage never shortens the next transition's measured duration" do
    task = Task.create!(title: "intent duration task", stage: "submitted")
    # Anchor the genesis (→submitted) event so the next transition measures from it.
    task.task_events.update_all(occurred_at: Time.zone.local(2026, 6, 22, 9, 0, 0))
    travel_to Time.zone.local(2026, 6, 22, 11, 0, 0) do
      task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    end
    travel_to Time.zone.local(2026, 6, 22, 11, 30, 0) do
      task.update!(stage: "reviewed")
    end

    reviewed = task.task_events.transitions.find_by(to_stage: "reviewed")
    assert_equal 9000, reviewed.seconds_in_from, "2.5h in submitted — measured from the prior TRANSITION, not the intent"
  end

  test "the reviewed transition reuses the pair recorded on the open review intent" do
    task = Task.create!(title: "intent reviewer tie task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    task.review! # no Current override → should adopt the intent's pair, not re-roll

    assert_equal REVIEWERS, task.task_events.transitions.find_by(to_stage: "reviewed").metadata["reviewers"]
  end
end
