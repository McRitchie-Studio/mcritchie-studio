# TaskIntelligence — the aggregation engine behind /intelligence (the task-
# development trends dashboard). A pure PORO: it owns ALL of the dashboard's math
# so the controller and view stay dumb (the controller just `.new`s it and the
# view reads its methods). Every public method returns Chartkick-ready data
# (arrays of [label, value] pairs, named-series arrays, or {label => value}
# hashes) or a plain Hash/Array for the table panels.
#
# Relations are injected (default to the whole table) so it is trivially unit
# testable: feed it a scoped set of Tasks/TaskEvents and assert the series.
#
# Data model recap (see TaskEvent):
#   * A TRANSITION row's `seconds_in_from` is the time the task spent in
#     `from_stage` before the move — so duration is grouped by from_stage.
#   * The agent-reported usage (model/tokens_in/tokens_out/cost) on a transition
#     is the work done IN the stage being left — so spend is also grouped by
#     from_stage. The genesis row (from_stage nil) carries neither, so it drops
#     out of every from_stage grouping naturally.
class TaskIntelligence
  # Sealed-bid t-shirt sizes → comparable points, so estimates and actuals can be
  # charted and differenced.
  SIZE_POINTS = { "small" => 1, "medium" => 2, "large" => 3, "xl" => 4 }.freeze
  SIZE_LABELS = { "small" => "S", "medium" => "M", "large" => "L", "xl" => "XL" }.freeze

  # How many tasks to surface in the per-task charts / leaderboards.
  TOP_N = 12

  # Tokens reported on a transition = tokens_in + tokens_out (either may be null).
  TOKENS_SQL = "COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)".freeze

  def initialize(tasks: Task.all, events: TaskEvent.all)
    @tasks = tasks
    @events = events
  end

  # ── Headline stat tiles ────────────────────────────────────────────────────
  def summary
    @summary ||= begin
      cycle = cycle_hours_by_task.values
      {
        total_tasks: @tasks.count,
        shipped_tasks: shipped_tasks.size,
        total_spend: transitions.sum(:cost).to_f.round(2),
        total_tokens: transitions.sum(Arel.sql(TOKENS_SQL)).to_i,
        total_events: @events.count,
        avg_cycle_hours: cycle.any? ? (cycle.sum / cycle.size).round(1) : 0.0,
        avg_cost_per_task: avg_cost_per_task,
        slowest_stage: slowest_stage,
        estimate_hit_rate: estimate_hit_rate
      }
    end
  end

  # ── 1. Stage speed — avg + median hours spent in each stage ─────────────────
  # Grouped column: which stages are slow. Grouped by from_stage (the stage left).
  def stage_speed_series
    buckets = seconds_by_stage
    stages = ordered_stages(buckets.keys)
    [
      { name: "Average", data: stages.map { |s| [stage_label(s), hours(average(buckets[s]))] } },
      { name: "Median",  data: stages.map { |s| [stage_label(s), hours(median(buckets[s]))] } }
    ]
  end

  # Median/average duration per TESTING phase across tasks, in MINUTES (testing
  # phases run far shorter than lifecycle stages). Reads each task's materialized
  # Task::TestingPhases projection. The fat bar here is the mandate to move that
  # phase's work off the builder's critical path.
  def testing_phase_speed_series
    buckets = testing_phase_seconds
    keys = Task::TestingPhases::PHASE_KEYS.select { |key| buckets[key].present? }
    [
      { name: "Average", data: keys.map { |key| [testing_phase_label(key), minutes(average(buckets[key]))] } },
      { name: "Median",  data: keys.map { |key| [testing_phase_label(key), minutes(median(buckets[key]))] } }
    ]
  end

  # ── 2. Task cycle time — created_at → completed_at per shipped task ──────────
  def cycle_time_per_task
    cycle_hours_by_task
      .sort_by { |_slug, hrs| -hrs }
      .first(TOP_N)
      .map { |slug, hrs| [task_label(slug), hrs] }
  end

  # Trend: average cycle time (hours) by the week each task completed. Weeks are
  # emitted as ordered, formatted labels (a discrete category axis) so the line
  # charts need no Chart.js date adapter.
  def cycle_time_trend
    by_week = Hash.new { |h, k| h[k] = [] }
    shipped_tasks.each do |task|
      week = task.completed_at.to_date.beginning_of_week(:monday)
      by_week[week] << cycle_hours(task)
    end
    by_week.sort_by(&:first).map { |week, hrs| [week_label(week), (hrs.sum / hrs.size).round(1)] }
  end

  # ── 3. Tokens ───────────────────────────────────────────────────────────────
  def tokens_per_task
    tokens_by_task
      .sort_by { |_slug, tokens| -tokens }
      .first(TOP_N)
      .map { |slug, tokens| [task_label(slug), tokens] }
  end

  # Where the tokens burn — total tokens reported per stage worked.
  def tokens_by_stage
    buckets = transitions.where.not(from_stage: nil)
                         .group(:from_stage).sum(Arel.sql(TOKENS_SQL))
    ordered_stages(buckets.keys).map { |s| [stage_label(s), buckets[s].to_i] }
  end

  # Tokens reported per event over time (groupdate weekly sum).
  def tokens_trend
    transitions.group_by_week(:occurred_at).sum(Arel.sql(TOKENS_SQL))
               .map { |week, tokens| [week_label(week), tokens.to_i] }
  end

  # ── 4. Cost ─────────────────────────────────────────────────────────────────
  def cost_per_task
    cost_by_task
      .sort_by { |_slug, cost| -cost }
      .first(TOP_N)
      .map { |slug, cost| [task_label(slug), cost] }
  end

  # Spend over time (groupdate weekly sum) — the cost-per-event trend.
  def cost_trend
    transitions.group_by_week(:occurred_at).sum(:cost)
               .map { |week, cost| [week_label(week), cost.to_f.round(2)] }
  end

  # ── 5. Estimate vs actual — po_size / dev_size vs actual_size ────────────────
  # Grouped column over tasks that have shipped with an actual_size recorded.
  def estimate_accuracy_series
    scored = sized_tasks
    [
      { name: "PO estimate",  data: scored.map { |t| [task_label(t.slug), size_points(t.po_size)] } },
      { name: "Dev estimate", data: scored.map { |t| [task_label(t.slug), size_points(t.dev_size)] } },
      { name: "Actual",       data: scored.map { |t| [task_label(t.slug), size_points(t.actual_size)] } }
    ]
  end

  # ── 6. Model mix — cost share by model (pie) ────────────────────────────────
  def model_mix
    transitions.where.not(model: [nil, ""]).group(:model).sum(:cost)
               .map { |model, cost| [model, cost.to_f.round(2)] }
               .sort_by { |_model, cost| -cost }
  end

  # ── Creative panels (tables) ────────────────────────────────────────────────
  # Priciest tasks leaderboard.
  def priciest_tasks
    cost_by_task.sort_by { |_slug, cost| -cost }.first(TOP_N).map do |slug, cost|
      { slug: slug, title: task_title(slug), cost: cost, tokens: tokens_by_task[slug].to_i }
    end
  end

  # Biggest estimate misses — |dev points − actual points|, largest first. Skip
  # any task missing EITHER size BEFORE the arithmetic: sizing (#209) derives
  # actual_size at ship even when the builder never stamped a dev_size, so
  # dev_size is commonly nil — and size_points(nil) is nil, so `actual - dev`
  # would raise a TypeError (this 500'd /intelligence on real data). filter_map
  # drops the skipped tasks in one pass.
  def biggest_estimate_misses
    sized_tasks.filter_map do |task|
      next unless task.dev_size && task.actual_size

      dev = size_points(task.dev_size)
      actual = size_points(task.actual_size)
      {
        slug: task.slug, title: task.title,
        dev_size: task.dev_size, actual_size: task.actual_size,
        delta: actual - dev
      }
    end.sort_by { |row| -row[:delta].abs }
       .first(TOP_N)
  end

  # Model usage breakdown table.
  def model_breakdown
    transitions.where.not(model: [nil, ""]).group(:model).count.keys.map do |model|
      rows = transitions.where(model: model)
      {
        model: model,
        events: rows.count,
        tokens: rows.sum(Arel.sql(TOKENS_SQL)).to_i,
        cost: rows.sum(:cost).to_f.round(2)
      }
    end.sort_by { |row| -row[:cost] }
  end

  private

  def transitions
    @transitions ||= @events.transitions
  end

  # task_slug => total tokens (transitions only).
  def tokens_by_task
    @tokens_by_task ||= transitions.where.not(task_slug: nil)
                                   .group(:task_slug).sum(Arel.sql(TOKENS_SQL))
                                   .transform_values(&:to_i)
  end

  # task_slug => total cost (transitions only), only tasks with spend.
  def cost_by_task
    @cost_by_task ||= transitions.where.not(task_slug: nil)
                                 .group(:task_slug).sum(:cost)
                                 .transform_values { |c| c.to_f.round(2) }
                                 .reject { |_slug, cost| cost.zero? }
  end

  # from_stage => [seconds, ...] (transitions with a measured duration).
  def seconds_by_stage
    @seconds_by_stage ||= transitions.where.not(seconds_in_from: nil)
                                     .where.not(from_stage: nil)
                                     .pluck(:from_stage, :seconds_in_from)
                                     .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(stage, secs), acc|
      acc[stage] << secs
    end
  end

  # Tasks that reached `shipped` (completed_at stamped).
  def shipped_tasks
    @shipped_tasks ||= @tasks.where.not(completed_at: nil).to_a
  end

  # slug => cycle hours, for shipped tasks.
  def cycle_hours_by_task
    @cycle_hours_by_task ||= shipped_tasks.each_with_object({}) do |task, acc|
      acc[task.slug] = cycle_hours(task)
    end
  end

  def cycle_hours(task)
    ((task.completed_at - task.created_at) / 3600.0).round(1)
  end

  # Tasks with both an actual size and at least one estimate — the accuracy set.
  def sized_tasks
    @sized_tasks ||= @tasks.where.not(actual_size: nil).order(:created_at).to_a
  end

  def avg_cost_per_task
    costs = cost_by_task.values
    costs.any? ? (costs.sum / costs.size).round(2) : 0.0
  end

  def estimate_hit_rate
    rows = sized_tasks.select(&:dev_size)
    return nil if rows.empty?

    hits = rows.count { |t| t.dev_size == t.actual_size }
    (100.0 * hits / rows.size).round
  end

  def slowest_stage
    buckets = seconds_by_stage
    return nil if buckets.empty?

    stage, secs = buckets.max_by { |_stage, list| average(list) }
    { stage: stage_label(stage), hours: hours(average(secs)) }
  end

  # task_slug => Task (for label/title resolution).
  def task_index
    @task_index ||= @tasks.index_by(&:slug)
  end

  def task_title(slug)
    task_index[slug]&.title || slug
  end

  # Short, chart-axis-friendly label (title truncated, falls back to slug).
  def task_label(slug)
    title = task_title(slug)
    title.length > 28 ? "#{title[0, 27]}…" : title
  end

  def stage_label(stage)
    Task::STAGE_LABELS.fetch(stage, stage.to_s.humanize)
  end

  # Week-start → short readable label ("Jun 1"). A string label keeps the trend
  # charts on a discrete category axis (no Chart.js date adapter needed).
  def week_label(week)
    week.strftime("%b %-d")
  end

  # Keep stages in workflow order, with any unknown stage appended.
  def ordered_stages(keys)
    known = Task::STAGES & keys
    known + (keys - Task::STAGES)
  end

  def size_points(size)
    SIZE_POINTS[size]
  end

  def average(list)
    return 0 if list.blank?

    list.sum.to_f / list.size
  end

  def median(list)
    return 0 if list.blank?

    sorted = list.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  # Seconds → hours, rounded for display.
  def hours(seconds)
    (seconds.to_f / 3600.0).round(2)
  end

  # Seconds → minutes, for the shorter testing-phase durations.
  def minutes(seconds)
    (seconds.to_f / 60.0).round(1)
  end

  def testing_phase_label(key)
    Task::TestingPhases::PHASE_DEFINITIONS.dig(key, "label") || key.to_s.humanize
  end

  # {phase_key => [completed seconds, ...]} across @tasks, read from each task's
  # materialized Task::TestingPhases projection (cached jsonb after backfill, so no
  # per-task query). Only completed windows count — in-progress/missing don't skew.
  def testing_phase_seconds
    Task::TestingPhases::PHASE_KEYS.index_with { [] }.tap do |acc|
      @tasks.each do |task|
        phases = Task::TestingPhases.cached_or_built(task)["phases"] || {}
        phases.each do |key, span|
          next unless acc.key?(key)

          acc[key] << span["seconds"] if span["status"] == "completed" && span["seconds"]
        end
      end
    end
  end
end
