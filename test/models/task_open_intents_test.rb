require "test_helper"

# Task#open_intents_for is ONE implementation over an event array: the board passes
# its preload as `events:`, and every other caller gets a fresh read of the task's
# intents and transitions. These cases pin the rule through both doors.
class TaskOpenIntentsTest < ActiveSupport::TestCase
  def open_ids(task, to_stage) = task.open_intents_for(to_stage).map(&:id)

  # Creating the task ALREADY stamps its own →submitted transition at Time.current
  # (the model does it on save), so the fixture backdates THAT event rather than
  # adding a second one. Adding one instead leaves the model's stamp sitting at
  # `now`, every backdated intent reads as belonging to a previous cycle, and both
  # paths correctly return nothing — a fixture that tests the guard, not the rule.
  def submitted_task(title, entered_at: 3.hours.ago)
    task = Task.create!(title: title, stage: "submitted")
    task.task_events.where(to_stage: "submitted").update_all(occurred_at: entered_at) # rubocop:disable Rails/SkipsModelValidations
    task.task_events.reset
    task
  end

  test "[unit] a plain open intent is open" do
    task = submitted_task("parity plain open intent")
    intent = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                      actor: "carl", occurred_at: 1.hour.ago)

    sql = open_ids(task, "reviewed")
    assert_equal [intent.id], sql
  end

  test "[unit] an intent from a PRIOR stage cycle is closed" do
    task = submitted_task("parity prior cycle intent")
    # A first review round, then QA rework put the task back into `submitted`.
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 2.hours.ago)
    task.task_events.create!(kind: "transition", from_stage: "reviewed", to_stage: "submitted",
                             actor: "avi", occurred_at: 90.minutes.ago)

    sql = open_ids(task, "reviewed")
    assert_empty sql, "the prior round's intent must be closed by the re-entry"
  end

  test "[unit] an intent the target transition superseded is closed" do
    task = submitted_task("parity target landed intent")
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 2.hours.ago)
    task.task_events.create!(kind: "transition", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 1.hour.ago)

    sql = open_ids(task, "reviewed")
    assert_empty sql
  end

  test "[unit] an intent a later exit from the source superseded is closed" do
    task = submitted_task("parity source exit intent")
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 2.hours.ago)
    # Left `submitted` some other way — a direct block/archive, not the target.
    task.task_events.create!(kind: "transition", from_stage: "submitted", to_stage: "archived",
                             actor: "xan", occurred_at: 30.minutes.ago)

    sql = open_ids(task, "reviewed")
    assert_empty sql
  end

  test "[unit] an occurred_at tie breaks on id" do
    moment = 1.hour.ago
    task = submitted_task("parity tie break intents", entered_at: moment)
    # Same instant as the stage entry: the id tiebreak decides, and a later id is inside
    # the cycle.
    same = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                    actor: "carl", occurred_at: moment)

    sql = open_ids(task, "reviewed")
    assert_equal [same.id], sql, "a later id at the same instant is inside the current cycle"
  end

  test "[unit] several intents can be open at once" do
    task = submitted_task("parity several open intents")
    first = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                     actor: "carl", occurred_at: 2.hours.ago)
    second = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                      actor: "xan", occurred_at: 1.hour.ago)

    sql = open_ids(task, "reviewed")
    # Order matters: open_intent_for takes .last, so chronological order is load-bearing.
    assert_equal [first.id, second.id], sql
  end

  test "[unit] a stage with no next intent has none" do
    task = Task.create!(title: "parity terminal stage task", stage: "shipped")
    task.task_events.create!(kind: "intent", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 1.hour.ago)

    sql = open_ids(task, "assembled")
    assert_empty sql
  end

  # The two doors: a preload is the event set the rule reads, and no preload is a
  # fresh read, so a stale association never hides a new intent on the write path.
  test "[unit] a preload is the event set the rule reads" do
    task = submitted_task("preload event set intents")
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 1.hour.ago)

    assert_empty task.open_intents_for("reviewed", events: []), "an empty preload has no intents"
  end

  test "[unit] with no preload the rule reads the database, not a loaded association" do
    task = submitted_task("fresh read intents")
    task.task_events.load
    intent = TaskEvent.create!(task: task, kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                               actor: "carl", occurred_at: 1.hour.ago)

    assert_equal [intent.id], open_ids(task, "reviewed")
  end
end
