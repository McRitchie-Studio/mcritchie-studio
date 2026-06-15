require "bigdecimal"

module Github
  class BuilderIndexCalculator
    DEFAULT_MINIMUM_COHORT_SIZE = 5

    def initialize(minimum_cohort_size: DEFAULT_MINIMUM_COHORT_SIZE)
      @minimum_cohort_size = minimum_cohort_size.to_i
    end

    def calculate!(start_date:, end_date:)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      weeks = Github::BuilderWeeklyAggregator.week_starts_between(start_date, end_date)
      count = 0

      weeks.each do |week_start|
        calculate_week!(week_start)
        count += 1
      end

      count
    end

    def self.median(values)
      sorted = values.compact.map { |value| BigDecimal(value.to_s) }.sort
      return nil if sorted.empty?

      midpoint = sorted.length / 2
      if sorted.length.odd?
        sorted[midpoint]
      else
        ((sorted[midpoint - 1] + sorted[midpoint]) / 2).round(4)
      end
    end

    private

    def calculate_week!(week_start)
      metrics = GithubBuilderWeeklyMetric.for_week(week_start).complete
      ai_values = metrics.where(cohort: "ai_builder").pluck(:builder_multiple)
      control_values = metrics.where(cohort: "control_builder").pluck(:builder_multiple)
      notes = incomplete_notes(ai_values, control_values)

      ai_median = nil
      control_median = nil
      adjusted = nil

      if notes.empty?
        ai_median = self.class.median(ai_values)
        control_median = self.class.median(control_values)
        if control_median&.positive?
          adjusted = (ai_median / control_median).round(4)
        else
          notes << "incomplete: control builder multiple is zero or missing"
        end
      end

      index_week = GithubBuilderIndexWeek.find_or_initialize_by(week_start_date: week_start)
      index_week.assign_attributes(
        ai_builder_multiple: ai_median,
        control_builder_multiple: control_median,
        difficulty_adjusted_ai_builder_multiple: adjusted,
        ai_builder_count: ai_values.size,
        control_builder_count: control_values.size,
        notes: notes.join("; ").presence
      )
      index_week.save!
    end

    def incomplete_notes(ai_values, control_values)
      notes = []
      if ai_values.size < @minimum_cohort_size
        notes << "incomplete: ai_builder_count #{ai_values.size} below minimum #{@minimum_cohort_size}"
      end
      if control_values.size < @minimum_cohort_size
        notes << "incomplete: control_builder_count #{control_values.size} below minimum #{@minimum_cohort_size}"
      end
      notes
    end

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end
  end
end
