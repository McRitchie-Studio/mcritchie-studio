require "csv"
require "fileutils"

module Github
  class BacktestCsvExporter
    DEFAULT_OUTPUT_DIR = Rails.root.join("tmp", "ai_builder_multiple")

    WEEKLY_COLUMNS = %w[
      week_start_date
      github_login
      cohort
      commits_count
      non_merge_commits_count
      bot_adjusted_commits_count
      active_repos_count
      trailing_90d_avg_weekly_commits
      builder_multiple
      bot_adjusted_builder_multiple
    ].freeze

    INDEX_COLUMNS = %w[
      week_start_date
      ai_builder_multiple
      control_builder_multiple
      difficulty_adjusted_ai_builder_multiple
      ai_builder_count
      control_builder_count
      notes
    ].freeze

    RANGE_CACHE_COLUMNS = %w[
      week_start_date
      week_end_date
      label
      github_login
      cohort
      commits_count
      non_merge_commits_count
      bot_adjusted_commits_count
      active_repos_count
      trailing_90d_avg_weekly_commits
      builder_multiple
      bot_adjusted_builder_multiple
      commit_shas
      cached_at
    ].freeze

    SAMPLE_COLUMNS = %w[
      github_login
      repo_full_name
      sha
      author_login
      committer_login
      authored_at
      committed_at
      is_merge
      is_bot
      source_strategy
      html_url
      message
    ].freeze

    def initialize(output_dir: DEFAULT_OUTPUT_DIR)
      @output_dir = Pathname(output_dir)
    end

    def export!(start_date:, end_date:, sample_limit: 500)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      FileUtils.mkdir_p(@output_dir)

      {
        weekly_metrics: export_weekly_metrics(start_date, end_date),
        range_caches: export_range_caches(start_date, end_date),
        index_weeks: export_index_weeks(start_date, end_date),
        commit_observations_sample: export_commit_sample(start_date, end_date, sample_limit)
      }
    end

    private

    def export_weekly_metrics(start_date, end_date)
      path = @output_dir.join("github_builder_weekly_metrics.csv")
      CSV.open(path, "w") do |csv|
        csv << WEEKLY_COLUMNS
        GithubBuilderWeeklyMetric
          .where(week_start_date: start_date.beginning_of_week(:monday)..end_date.beginning_of_week(:monday))
          .order(:week_start_date, :cohort, :github_login)
          .each do |metric|
            csv << WEEKLY_COLUMNS.map { |column| metric.public_send(column) }
          end
      end
      path
    end

    def export_range_caches(start_date, end_date)
      path = @output_dir.join("github_builder_commit_range_caches.csv")
      CSV.open(path, "w") do |csv|
        csv << RANGE_CACHE_COLUMNS
        GithubBuilderCommitRangeCache
          .joins(:github_commit_range)
          .where(github_commit_ranges: {
            week_start_date: start_date.beginning_of_week(:monday)..end_date.beginning_of_week(:monday)
          })
          .order("github_commit_ranges.week_start_date ASC", :cohort, :github_login)
          .includes(:github_commit_range)
          .each do |cache|
            range = cache.github_commit_range
            csv << [
              range.week_start_date,
              range.week_end_date,
              range.display_label,
              cache.github_login,
              cache.cohort,
              cache.commits_count,
              cache.non_merge_commits_count,
              cache.bot_adjusted_commits_count,
              cache.active_repos_count,
              cache.trailing_90d_avg_weekly_commits,
              cache.builder_multiple,
              cache.bot_adjusted_builder_multiple,
              cache.commit_shas.join(" "),
              cache.cached_at
            ]
          end
      end
      path
    end

    def export_index_weeks(start_date, end_date)
      path = @output_dir.join("github_builder_index_weeks.csv")
      CSV.open(path, "w") do |csv|
        csv << INDEX_COLUMNS
        GithubBuilderIndexWeek
          .where(week_start_date: start_date.beginning_of_week(:monday)..end_date.beginning_of_week(:monday))
          .order(:week_start_date)
          .each do |week|
            csv << INDEX_COLUMNS.map { |column| week.public_send(column) }
          end
      end
      path
    end

    def export_commit_sample(start_date, end_date, sample_limit)
      path = @output_dir.join("github_commit_observations_sample.csv")
      CSV.open(path, "w") do |csv|
        csv << SAMPLE_COLUMNS
        GithubCommitObservation
          .where(
            "(committed_at >= ? AND committed_at <= ?) OR " \
            "(committed_at IS NULL AND authored_at >= ? AND authored_at <= ?)",
            start_date.beginning_of_day, end_date.end_of_day,
            start_date.beginning_of_day, end_date.end_of_day
          )
          .order(committed_at: :desc, authored_at: :desc)
          .limit(sample_limit)
          .each do |observation|
            csv << SAMPLE_COLUMNS.map { |column| observation.public_send(column) }
          end
      end
      path
    end

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end
  end
end
