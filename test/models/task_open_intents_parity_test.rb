require "test_helper"

# Task#open_intents_for now has TWO implementations of one rule: a SQL path (the
# default, used by the write-side idempotency guard in record_intent_event) and a
# Ruby path over a caller-supplied event array (the board's preload).
#
# Two implementations of one rule is a divergence waiting to happen, and a
# divergence here is not a slow board — it is the wrong answer about whether a
# review is live, on the write path that decides whether to open a duplicate
# intent. So every case below asserts PARITY: the same task, both paths, same
# result. A change to either branch that does not change the other fails here.
#
# Its own file rather than an append to task_test.rb, which is a declared APPEND
# hotspot (config/test_health.yml).
class TaskOpenIntentsParityTest < ActiveSupport::TestCase
  def assert_parity(task, to_stage, message)
    events = task.task_events.reload.to_a
    sql = task.open_intents_for(to_stage).map(&:id)
    ruby = task.open_intents_for(to_stage, events: events).map(&:id)

    assert_equal sql, ruby, "SQL and preload paths disagree — #{message}"
    [sql, ruby]
  end

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

  test "[unit] both paths see a plain open intent" do
    task = submitted_task("parity plain open intent")
    intent = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                      actor: "carl", occurred_at: 1.hour.ago)

    sql, = assert_parity(task, "reviewed", "a live review intent")
    assert_equal [intent.id], sql
  end

  test "[unit] both paths reject an intent from a PRIOR stage cycle" do
    task = submitted_task("parity prior cycle intent")
    # A first review round, then QA rework put the task back into `submitted`.
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 2.hours.ago)
    task.task_events.create!(kind: "transition", from_stage: "reviewed", to_stage: "submitted",
                             actor: "avi", occurred_at: 90.minutes.ago)

    sql, = assert_parity(task, "reviewed", "an intent from the previous submitted cycle")
    assert_empty sql, "the prior round's intent must be closed by the re-entry"
  end

  test "[unit] both paths reject an intent the target transition superseded" do
    task = submitted_task("parity target landed intent")
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 2.hours.ago)
    task.task_events.create!(kind: "transition", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 1.hour.ago)

    sql, = assert_parity(task, "reviewed", "the →reviewed transition landed after the intent")
    assert_empty sql
  end

  test "[unit] both paths reject an intent a later exit from the source superseded" do
    task = submitted_task("parity source exit intent")
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 2.hours.ago)
    # Left `submitted` some other way — a direct block/archive, not the target.
    task.task_events.create!(kind: "transition", from_stage: "submitted", to_stage: "archived",
                             actor: "alex", occurred_at: 30.minutes.ago)

    sql, = assert_parity(task, "reviewed", "a later transition OUT of the source stage")
    assert_empty sql
  end

  test "[unit] both paths break an occurred_at tie the same way" do
    moment = 1.hour.ago
    task = submitted_task("parity tie break intents", entered_at: moment)
    # Same instant as the stage entry: the id tiebreak decides, and it must decide
    # identically on both sides (>= entry.id in Ruby, id >= in SQL).
    same = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                    actor: "carl", occurred_at: moment)

    sql, = assert_parity(task, "reviewed", "an intent at the same instant as the stage entry")
    assert_equal [same.id], sql, "a later id at the same instant is inside the current cycle"
  end

  test "[unit] both paths agree when several intents are open at once" do
    task = submitted_task("parity several open intents")
    first = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                     actor: "carl", occurred_at: 2.hours.ago)
    second = task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                                      actor: "alex", occurred_at: 1.hour.ago)

    sql, = assert_parity(task, "reviewed", "two live intents toward the same target")
    # Order matters: open_intent_for takes .last, so chronological order is load-bearing.
    assert_equal [first.id, second.id], sql
  end

  test "[unit] both paths return nothing for a stage with no next intent" do
    task = Task.create!(title: "parity terminal stage task", stage: "shipped")
    task.task_events.create!(kind: "intent", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 1.hour.ago)

    sql, = assert_parity(task, "assembled", "a shipped task has no next intent stage")
    assert_empty sql
  end
end
