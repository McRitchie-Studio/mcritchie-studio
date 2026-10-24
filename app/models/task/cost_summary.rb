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
# DURATIONS come from the stage-stamp columns Task#set_stage_timestamp writes, in
# whole seconds, keyed by the stage the span covers:
#
#   design    created_at   -> started_at    (created to claimed)
#   build     started_at   -> submitted_at
#   review    submitted_at -> reviewed_at
#   assemble  reviewed_at  -> assembled_at
#   ship      assembled_at -> completed_at  (completed_at is the shipped stamp)
#
# A span is nil when either end is missing (the stage never happened) or the end
# precedes the start (a later re-entry restamped the start, so the pair no longer
# brackets one pass). Each stamp holds the LATEST entry into its stage, so a
# resubmitted task's build span runs from its claim to its last submit.
class Task::CostSummary
  COST_BUCKETS = {
    "build"  => [nil, "designed", "building"],
    "review" => ["submitted"],
    "deploy" => %w[reviewed assembled]
  }.freeze
  OTHER_BUCKET = "other"
  COST_KEYS = [*COST_BUCKETS.keys, OTHER_BUCKET].freeze

  DURATION_SPANS = {
    "design"   => %i[created_at started_at],
    "build"    => %i[started_at submitted_at],
    "review"   => %i[submitted_at reviewed_at],
    "assemble" => %i[reviewed_at assembled_at],
    "ship"     => %i[assembled_at completed_at]
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
    DURATION_SPANS.transform_values do |(from, to)|
      start = @task.public_send(from)
      finish = @task.public_send(to)
      next nil if start.nil? || finish.nil? || finish < start

      (finish - start).round
    end
  end

  private

  # One grouped query over the priced rows: { from_stage => BigDecimal }. A NULL
  # cost is left out, so a stage that only ever recorded the spine stays absent.
  def priced_sums_by_from_stage
    @priced_sums_by_from_stage ||=
      TaskEvent.where(task_slug: @task.slug).where.not(cost: nil).group(:from_stage).sum(:cost)
  end

  def bucket_for(from_stage)
    COST_BUCKETS.find { |_bucket, stages| stages.include?(from_stage) }&.first || OTHER_BUCKET
  end

  def to_usd(value)
    value.to_d.round(SCALE).to_f
  end
end
