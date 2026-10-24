# frozen_string_literal: true

# The `cost:` and `time:` lines `bin/task show` prints, rendered from the three
# fields `GET /api/v1/tasks/:slug` carries (Task::CostSummary):
#
#   cost: $12.35  build $8.00 · review $3.00 · deploy $1.35
#   time: design 2h 3m · build 45m · review 20m · assemble - · ship -
#
# Plain Ruby, no Rails, so bin/task requires it directly. `-` is a stage with
# nothing measured (cost) or a span that never happened (time); it is never 0.
# A record without the fields (an older board, a PATCH echo) prints no lines.
module TaskCostLine
  COST_KEYS = %w[build review deploy].freeze
  OTHER_KEY = "other"
  DURATION_KEYS = %w[design build review assemble ship].freeze

  module_function

  # The lines for one task record (a Hash from the API), or [] when it carries
  # none of the fields.
  def lines(task)
    return [] unless task.is_a?(Hash)
    return [] unless %w[total_cost cost_by_stage durations_by_stage].any? { |key| task.key?(key) }

    [cost_line(task), time_line(task)]
  end

  def cost_line(task)
    by_stage = task["cost_by_stage"].is_a?(Hash) ? task["cost_by_stage"] : {}
    parts = COST_KEYS.map { |key| "#{key} #{usd(by_stage[key])}" }
    parts << "#{OTHER_KEY} #{usd(by_stage[OTHER_KEY])}" unless by_stage[OTHER_KEY].nil?
    "cost: #{usd(task["total_cost"])}  #{parts.join(" · ")}"
  end

  def time_line(task)
    spans = task["durations_by_stage"].is_a?(Hash) ? task["durations_by_stage"] : {}
    "time: " + DURATION_KEYS.map { |key| "#{key} #{elapsed(spans[key])}" }.join(" · ")
  end

  def usd(value)
    return "-" if value.nil?

    format("$%.2f", Float(value))
  rescue ArgumentError, TypeError
    "-"
  end

  # Seconds as the two largest units: 3d 4h, 2h 3m, 45m, 30s.
  def elapsed(seconds)
    return "-" if seconds.nil?

    total = Integer(seconds)
    return "-" if total.negative?

    days, rest = total.divmod(86_400)
    hours, rest = rest.divmod(3600)
    minutes, secs = rest.divmod(60)
    if days.positive? then "#{days}d #{hours}h"
    elsif hours.positive? then "#{hours}h #{minutes}m"
    elsif minutes.positive? then "#{minutes}m"
    else "#{secs}s"
    end
  rescue ArgumentError, TypeError
    "-"
  end
end
