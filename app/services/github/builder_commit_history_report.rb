module Github
  class BuilderCommitHistoryReport
    Quarter = Struct.new(:year, :quarter, :ranges, keyword_init: true) do
      def key
        [year, quarter]
      end

      def label
        "#{year} Q#{quarter}"
      end

      def start_date
        ranges.map(&:week_start_date).min
      end

      def end_date
        ranges.map(&:week_end_date).max
      end

      def title
        "#{start_date.strftime("%b %-d, %Y")} through #{end_date.strftime("%b %-d, %Y")}"
      end
    end

    attr_reader :builders, :ranges, :years, :quarters, :rows

    def initialize(builders:, start_date: Github::BuilderWeeklyAggregator::REPORT_START_DATE, end_date: nil)
      @builders = builders.to_a
      @start_date = start_date.to_date
      @end_date = end_date&.to_date
      @ranges = []
      @years = []
      @quarters = []
      @rows = []
    end

    def build
      @ranges = load_ranges
      @years = ranges.map { |range| range.week_end_date.year }.uniq.sort.reverse
      @quarters = build_quarters
      @rows = build_rows
      self
    end

    def date_range_label
      return "No cached ranges" if ranges.blank?

      "#{ranges.last.week_start_date.strftime("%b %-d, %Y")} through #{ranges.first.week_end_date.strftime("%b %-d, %Y")}"
    end

    def chart_quarters
      quarters.reverse
    end

    def complete_rows_count
      rows.count { |row| row[:cached_range_count] >= ranges.size }
    end

    def incomplete_rows_count
      rows.size - complete_rows_count
    end

    private

    attr_reader :start_date, :end_date

    def load_ranges
      scope = GithubCommitRange.where(week_start_date: start_date..)
      scope = scope.where("week_start_date <= ?", end_date) if end_date.present?

      scope.recent.to_a.select { |range| range.week_start_date.saturday? }
    end

    def build_quarters
      ranges
        .group_by { |range| [range.week_end_date.year, quarter_for(range.week_end_date)] }
        .map do |(year, quarter), quarter_ranges|
          Quarter.new(year: year, quarter: quarter, ranges: quarter_ranges.sort_by(&:week_start_date))
        end
        .sort_by { |quarter| [quarter.year, quarter.quarter] }
        .reverse
    end

    def build_rows
      tracked_by_login = TrackedGithubBuilder
        .where(github_login: builders.map(&:github_login))
        .index_by(&:github_login)
      caches_by_key = load_caches(tracked_by_login.values)

      builders.map do |builder|
        tracked = tracked_by_login[builder.github_login]
        weekly_counts = ranges.to_h do |range|
          cache = tracked ? caches_by_key[[tracked.id, range.id]] : nil
          [range.id, cache&.commits_count]
        end

        {
          builder: builder,
          tracked_builder: tracked,
          weekly_counts: weekly_counts,
          cached_range_count: weekly_counts.values.count { |count| !count.nil? },
          total_commits_count: weekly_counts.values.compact.sum,
          year_totals: year_totals(weekly_counts),
          quarter_totals: quarter_totals(weekly_counts)
        }
      end.sort_by do |row|
        builder = row[:builder]
        [-row[:total_commits_count], builder.display_name.downcase, builder.github_login]
      end
    end

    def load_caches(tracked_builders)
      return {} if ranges.blank? || tracked_builders.blank?

      GithubBuilderCommitRangeCache
        .where(tracked_github_builder_id: tracked_builders.map(&:id), github_commit_range_id: ranges.map(&:id))
        .index_by { |cache| [cache.tracked_github_builder_id, cache.github_commit_range_id] }
    end

    def year_totals(weekly_counts)
      years.to_h do |year|
        total = ranges
          .select { |range| range.week_end_date.year == year }
          .sum { |range| weekly_counts[range.id].to_i }
        [year, total]
      end
    end

    def quarter_totals(weekly_counts)
      quarters.to_h do |quarter|
        total = quarter.ranges.sum { |range| weekly_counts[range.id].to_i }
        [quarter.key, total]
      end
    end

    def quarter_for(date)
      ((date.month - 1) / 3) + 1
    end
  end
end
