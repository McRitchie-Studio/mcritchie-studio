# frozen_string_literal: true

# What a task cost, in USD, and how long each stage took — the two numbers the
# operator reads off a card (time first, token cost second). Read-only: it sums
# what the event spine already holds and writes nothing.
#
#   summary = Task::CostSummary.new(task)
#   summary.total_cost          # => 12.3456 (Float), or nil when no event is priced
#   summary.cost_by_stage       # => { "build" => 8.0, "review" => 3.0, "deploy" => nil, "other" => nil }
#   summary.durations_by_stage  # => { "design" => 7380, "build" => 2700, "review" => nil, ... } (seconds)
#
# Both sums read every event kind's cost (as Task#total_cost does), but only
# transitions' durations. Two grouped queries per task; the show API calls it for
# one task, never per row of the index.
#
# COST comes from `task_events.cost` (see docs/agents/system/agent-usage.md, "Task
# cost"). Each priced row is the usage a session burned in the stage it was
# standing in when it wrote the row, which is the row's `from_stage` for a
# transition (the stage being left) and for a checkpoint alike (the task's stage
# at the checkpoint). An intent carries no usage. So the bucket is read off
# `from_stage`:
#
#   build   from nil (the genesis row), designed, building
#   review  from submitted (the reviewer's verdict move, a block included)
#   deploy  from reviewed, assembled (qa-release's assemble, the ship)
#   other   anything else (a row written from shipped or archived)
#
# A bucket with no priced row is nil, never 0: "nothing was measured" and "it was
# free" are different facts.
#
# DURATIONS are the whole seconds the task spent in each stage, summed over the
# transition spine: each transition's `seconds_in_from` is the time since the
# previous transition, which is time spent in its `from_stage` (the reading
# TaskIntelligence#seconds_by_stage and AppDevopsStages::Eta already use). Summing
# per stage counts every pass, so a blocked and resubmitted task's build time is
# both builds and its review time both reviews. Keyed by the span the stage covers:
#
#   design    time in designed   (created -> claimed)
#   build     time in building   (claimed -> submitted; a block lands here)
#   review    time in submitted  (submitted -> reviewed, or -> sent back)
#   assemble  time in reviewed   (reviewed -> assembled)
#   ship      time in assembled  (assembled -> shipped)
#
# A span is nil, never 0, when no transition ever LEFT that stage: the stage never
# happened, or the task is in it now. Intents and checkpoints carry no
# seconds_in_from and are not stage boundaries, so only transitions count.
class Task::CostSummary
  COST_BUCKETS = {
    "build"  => [nil, "designed", "building"],
    "review" => ["submitted"],
    "deploy" => %w[reviewed assembled]
  }.freeze
  OTHER_BUCKET = "other"
  COST_KEYS = [*COST_BUCKETS.keys, OTHER_BUCKET].freeze

  # Duration key => the stage whose time it measures.
  DURATION_STAGES = {
    "design"   => "designed",
    "build"    => "building",
    "review"   => "submitted",
    "assemble" => "reviewed",
    "ship"     => "assembled"
  }.freeze

  # USD is rounded to four places, the column's own scale.
  SCALE = 4

  def initialize(task)
    @task = task
  end

  # The read API's three fields, merged into `GET /api/v1/tasks/:slug`.
  def as_json(*)
    {
      "total_cost" => total_cost,
      "cost_by_stage" => cost_by_stage,
      "durations_by_stage" => durations_by_stage
    }
  end

  def total_cost
    sums = priced_sums_by_from_stage
    return nil if sums.empty?

    to_usd(sums.values.sum)
  end

  def cost_by_stage
    sums = priced_sums_by_from_stage
    COST_KEYS.index_with do |bucket|
      matched = sums.select { |from, _| bucket_for(from) == bucket }
      matched.empty? ? nil : to_usd(matched.values.sum)
    end
  end

  def durations_by_stage
    seconds = seconds_by_from_stage
    DURATION_STAGES.transform_values { |stage| seconds[stage] }
  end

  private

  # One grouped query over the priced rows: { from_stage => BigDecimal }. A NULL
  # cost is left out, so a stage that only ever recorded the spine stays absent.
  def priced_sums_by_from_stage
    @priced_sums_by_from_stage ||=
      TaskEvent.where(task_slug: @task.slug).where.not(cost: nil).group(:from_stage).sum(:cost)
  end

  # One grouped query over the transition spine: { from_stage => Integer }. A
  # stage no transition left is absent (SUM over no row), and a row whose
  # seconds_in_from is NULL (the genesis row) adds nothing.
  def seconds_by_from_stage
    TaskEvent.transitions.where(task_slug: @task.slug).where.not(seconds_in_from: nil)
             .group(:from_stage).sum(:seconds_in_from).transform_values(&:to_i)
  end

  def bucket_for(from_stage)
    COST_BUCKETS.find { |_bucket, stages| stages.include?(from_stage) }&.first || OTHER_BUCKET
  end

  def to_usd(value)
    value.to_d.round(SCALE).to_f
  end
end
