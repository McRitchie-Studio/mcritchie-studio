require "test_helper"

# [unit] TaskIntelligence is the aggregation engine behind /intelligence. Feed it
# a known, hand-built set of Tasks + TaskEvents and assert every computed series
# — durations grouped by the stage left, spend/tokens summed from transitions,
# cycle time from created→completed, and estimate-vs-actual size points.
class TaskIntelligenceTest < ActiveSupport::TestCase
  setup do
    # Start from a clean slate so the default Task.all / TaskEvent.all relations
    # see only the fixtures we build here (clear events first — FK on task_slug).
    TaskEvent.delete_all
    Task.delete_all

    # Both tasks complete in the same week so the weekly trend buckets to one row.
    @week_anchor = Time.utc(2026, 6, 3, 12) # a Wednesday

    @t1 = build_task(
      slug: "intel-t1", title: "Estimate over by one",
      po: "medium", dev: "large", actual: "xl",
      created: @week_anchor - 10.hours, completed: @week_anchor
    )
    add_event(@t1, from: "building",  to: "submitted", secs: 7_200,  tin: 100, tout: 200, cost: 5.0, model: "claude-opus-4-8")
    add_event(@t1, from: "submitted", to: "reviewed",  secs: 3_600,  tin: 10,  tout: 20,  cost: 1.0, model: "claude-haiku-4")

    @t2 = build_task(
      slug: "intel-t2", title: "Estimate dead on",
      po: "small", dev: "small", actual: "small",
      created: @week_anchor - 5.hours, completed: @week_anchor
    )
    add_event(@t2, from: "building", to: "submitted", secs: 10_800, tin: 50, tout: 50, cost: 2.0, model: "claude-opus-4-8")

    @intel = TaskIntelligence.new
  end

  test "summary rolls up totals, spend, tokens, cycle and estimate hit rate" do
    s = @intel.summary
    assert_equal 2, s[:total_tasks]
    assert_equal 2, s[:shipped_tasks]
    assert_in_delta 8.0, s[:total_spend], 0.001          # 5 + 1 + 2
    assert_equal 430, s[:total_tokens]                    # 300 + 30 + 100
    assert_in_delta 7.5, s[:avg_cycle_hours], 0.001       # (10 + 5) / 2
    assert_equal 50, s[:estimate_hit_rate]                # t2 hits, t1 misses
    assert_equal "Building", s[:slowest_stage][:stage]
  end

  test "stage_speed_series reports avg + median hours by the stage left" do
    avg = Hash[@intel.stage_speed_series.find { |sr| sr[:name] == "Average" }[:data]]
    assert_in_delta 2.5, avg["Building"], 0.001           # (7200 + 10800)/2 = 9000s
    assert_in_delta 1.0, avg["Submitted"], 0.001          # 3600s
    median = Hash[@intel.stage_speed_series.find { |sr| sr[:name] == "Median" }[:data]]
    assert_in_delta 2.5, median["Building"], 0.001
  end

  test "cycle time per task and weekly trend" do
    per_task = Hash[@intel.cycle_time_per_task]
    assert_in_delta 10.0, per_task["Estimate over by one"], 0.001
    assert_in_delta 5.0, per_task["Estimate dead on"], 0.001

    trend = @intel.cycle_time_trend
    assert_equal 1, trend.size                            # both shipped same week
    assert_in_delta 7.5, trend.first.last, 0.001
  end

  test "tokens per task and tokens by stage" do
    per_task = Hash[@intel.tokens_per_task]
    assert_equal 330, per_task["Estimate over by one"]    # 300 + 30
    assert_equal 100, per_task["Estimate dead on"]

    by_stage = Hash[@intel.tokens_by_stage]
    assert_equal 400, by_stage["Building"]                # 300 + 100
    assert_equal 30, by_stage["Submitted"]
  end

  test "cost per task and model mix" do
    per_task = Hash[@intel.cost_per_task]
    assert_in_delta 6.0, per_task["Estimate over by one"], 0.001
    assert_in_delta 2.0, per_task["Estimate dead on"], 0.001

    mix = Hash[@intel.model_mix]
    assert_in_delta 7.0, mix["claude-opus-4-8"], 0.001    # 5 + 2
    assert_in_delta 1.0, mix["claude-haiku-4"], 0.001
  end

  test "estimate accuracy series and biggest misses" do
    actual = Hash[@intel.estimate_accuracy_series.find { |sr| sr[:name] == "Actual" }[:data]]
    assert_equal 4, actual["Estimate over by one"]        # xl
    assert_equal 1, actual["Estimate dead on"]            # small

    misses = @intel.biggest_estimate_misses
    assert_equal "intel-t1", misses.first[:slug]          # |+1| sorts ahead of 0
    assert_equal 1, misses.first[:delta]
  end

  # Regression: sizing (#209) derives actual_size at ship even when the builder
  # never stamped a dev_size, so dev_size is commonly nil. biggest_estimate_misses
  # must SKIP such a task — not raise a TypeError on `actual - nil` (this 500'd
  # /intelligence on real data).
  test "biggest_estimate_misses skips a shipped task with actual_size but no dev_size" do
    no_dev = build_task(
      slug: "intel-no-dev", title: "Actual without dev estimate",
      po: nil, dev: nil, actual: "large",
      created: @week_anchor - 3.hours, completed: @week_anchor
    )
    add_event(no_dev, from: "building", to: "submitted", secs: 3_600, tin: 10, tout: 10, cost: 0.5, model: "claude-haiku-4")

    intel = TaskIntelligence.new
    misses = assert_nothing_raised { intel.biggest_estimate_misses }
    slugs = misses.map { |row| row[:slug] }
    assert_not_includes slugs, "intel-no-dev"
    assert_includes slugs, "intel-t1" # the well-formed sibling is still ranked
  end

  # The summary tiles + estimate charts (same accuracy set) must also survive a
  # dev_size-less shipped task without raising.
  test "summary and estimate series survive a shipped task with actual_size but no dev_size" do
    build_task(slug: "intel-no-dev-2", title: "Another actual no dev",
               po: nil, dev: nil, actual: "medium",
               created: @week_anchor - 2.hours, completed: @week_anchor)
    intel = TaskIntelligence.new
    assert_nothing_raised { intel.summary }
    assert_nothing_raised { intel.estimate_accuracy_series }
  end

  test "priciest tasks leaderboard ranks by total spend" do
    rows = @intel.priciest_tasks
    assert_equal "intel-t1", rows.first[:slug]
    assert_in_delta 6.0, rows.first[:cost], 0.001
    assert_equal 330, rows.first[:tokens]
  end

  test "model breakdown aggregates events, tokens and cost per model" do
    opus = @intel.model_breakdown.find { |r| r[:model] == "claude-opus-4-8" }
    assert_equal 2, opus[:events]
    assert_equal 400, opus[:tokens]                       # 300 + 100
    assert_in_delta 7.0, opus[:cost], 0.001
  end

  test "handles an empty dataset without raising" do
    TaskEvent.delete_all
    Task.delete_all
    intel = TaskIntelligence.new
    assert_equal 0, intel.summary[:total_tasks]
    assert_equal 0.0, intel.summary[:avg_cycle_hours]
    assert_nil intel.summary[:estimate_hit_rate]
    assert_empty intel.cycle_time_per_task
    assert_empty intel.model_mix
  end

  private

  def build_task(slug:, title:, po:, dev:, actual:, created:, completed:)
    task = Task.create!(title: title, slug: slug, stage: "shipped",
                        po_size: po, dev_size: dev, actual_size: actual)
    task.task_events.delete_all # drop the auto-genesis; we add curated events
    task.update_columns(created_at: created, completed_at: completed, updated_at: completed)
    task
  end

  def add_event(task, from:, to:, secs:, tin:, tout:, cost:, model:)
    TaskEvent.create!(
      task_slug: task.slug, from_stage: from, to_stage: to,
      occurred_at: task.completed_at, seconds_in_from: secs,
      tokens_in: tin, tokens_out: tout, cost: cost, model: model,
      source: "cli", kind: TaskEvent::TRANSITION
    )
  end
end
