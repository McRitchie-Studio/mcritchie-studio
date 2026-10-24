# frozen_string_literal: true

require "test_helper"

# [unit] task-show-prints-cost: Task::CostSummary sums task_events.cost into the
# build / review / deploy buckets by from_stage, and measures each stage span off
# the stage stamps, nil (never 0) where a stage never happened.
class Task::CostSummaryTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:in_progress_task)
    @created = Time.zone.parse("2026-04-01 10:00:00")
  end

  def priced(from, to, cost, kind: TaskEvent::TRANSITION)
    TaskEvent.create!(task_slug: @task.slug, from_stage: from, to_stage: to, kind: kind,
                      occurred_at: @created, cost: cost)
  end

  test "three priced events bucket by the stage the session stood in" do
    priced("building", "submitted", "8.1234")
    priced("submitted", "reviewed", "3.5")
    priced("reviewed", "assembled", "1.25")
    # Spine-only rows (no cost) never turn a bucket from nil into 0.
    TaskEvent.create!(task_slug: @task.slug, from_stage: "assembled", to_stage: "shipped", occurred_at: @created)

    summary = Task::CostSummary.new(@task)

    assert_in_delta 12.8734, summary.total_cost, 0.00001
    assert_equal({ "build" => 8.1234, "review" => 3.5, "deploy" => 1.25, "other" => nil }, summary.cost_by_stage)
  end

  test "a checkpoint's cost lands in the bucket of the stage it was recorded in" do
    priced("submitted", "heavy_review", "2.0", kind: TaskEvent::CHECKPOINT)
    priced(nil, "designed", "0.5")
    priced("shipped", "archived", "0.1")

    by_stage = Task::CostSummary.new(@task).cost_by_stage

    assert_equal 0.5, by_stage["build"], "the genesis row is design work, in build"
    assert_equal 2.0, by_stage["review"]
    assert_nil by_stage["deploy"]
    assert_equal 0.1, by_stage["other"]
  end

  test "no priced event is nil, not zero" do
    TaskEvent.create!(task_slug: @task.slug, from_stage: "designed", to_stage: "building", occurred_at: @created)

    summary = Task::CostSummary.new(@task)

    assert_nil summary.total_cost
    assert(summary.cost_by_stage.values.all?(&:nil?))
  end

  def moved(from, to, seconds, kind: TaskEvent::TRANSITION)
    TaskEvent.create!(task_slug: @task.slug, from_stage: from, to_stage: to, kind: kind,
                      occurred_at: @created, seconds_in_from: seconds)
  end

  test "durations sum the seconds spent in each stage, in whole seconds" do
    moved(nil, "designed", nil) # the genesis row measures nothing
    moved("designed", "building", 7380)
    moved("building", "submitted", 3420)
    moved("submitted", "reviewed", 1200)
    moved("reviewed", "assembled", 6000)
    moved("assembled", "shipped", 30)

    assert_equal({ "design" => 7380, "build" => 3420, "review" => 1200, "assemble" => 6000, "ship" => 30 },
                 Task::CostSummary.new(@task).durations_by_stage)
  end

  # The control: a task still in review has left designed and building but never
  # left submitted, so review, assemble and ship are nil — never 0, which would
  # read as "instant".
  test "a stage that never happened is nil, not zero" do
    moved("designed", "building", 3600)
    moved("building", "submitted", 3600)

    spans = Task::CostSummary.new(@task).durations_by_stage

    assert_equal 3600, spans["design"]
    assert_equal 3600, spans["build"]
    assert_nil spans["review"]
    assert_nil spans["assemble"]
    assert_nil spans["ship"]
  end

  test "a reworked task sums every pass through a stage" do
    moved("building", "submitted", 1000)
    moved("submitted", "building", 300) # the reviewer's send-back
    moved("building", "submitted", 500)
    moved("submitted", "reviewed", 200)

    spans = Task::CostSummary.new(@task).durations_by_stage

    assert_equal 1500, spans["build"]
    assert_equal 500, spans["review"]
  end

  test "intents and checkpoints are not stage boundaries" do
    moved("building", "submitted", 600)
    moved("submitted", "reviewed", 999, kind: TaskEvent::INTENT)
    moved("submitted", "heavy_review", 999, kind: TaskEvent::CHECKPOINT)

    spans = Task::CostSummary.new(@task).durations_by_stage

    assert_equal 600, spans["build"]
    assert_nil spans["review"]
  end
end
