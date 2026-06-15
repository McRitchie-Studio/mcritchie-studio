module Admin
  class AiBuilderMultipleController < ApplicationController
    before_action :require_admin

    def index
      @limit = [[params.fetch(:limit, 26).to_i, 1].max, 52].min
      @builder_limit = [[params.fetch(:builder_limit, 100).to_i, 1].max, 1_000].min
      @index_weeks = report_index_weeks.first(@limit)
      @chart_weeks = @index_weeks.reverse
      @latest_week = @index_weeks.first&.week_start_date
      @observed_through_date = GithubCommitObservation.maximum(:committed_at)&.to_date
      @latest_metrics = @latest_week ? GithubBuilderWeeklyMetric.for_week(@latest_week).order(:cohort, :github_login).to_a : []
      @builder_metrics_week = representative_metrics_week
      @builder_metrics = @builder_metrics_week ? GithubBuilderWeeklyMetric.for_week(@builder_metrics_week).order(:cohort, :github_login).to_a : []
      @metrics_boundary_week_excluded = @builder_metrics_week.present? && @latest_week.present? && @builder_metrics_week != @latest_week
      @commit_log_ranges = commit_log_ranges
      @commit_log_rows = commit_log_rows
      @tracked_builder_summary = tracked_builder_summary
      @overview = overview_summary
      @builder_rollups = builder_rollups
      @minimum_cohort_size = Github::BuilderIndexCalculator::DEFAULT_MINIMUM_COHORT_SIZE

      respond_to do |format|
        format.html
        format.json { render json: { data: json_payload } }
      end
    end

    private

    def json_payload
      {
        caveat: caveat,
        latest_week_start_date: @latest_week,
        tracked_builders: @tracked_builder_summary,
        overview: @overview,
        index_weeks: @index_weeks.map { |week| index_week_json(week) },
        latest_builder_weekly_metrics: @latest_metrics.map { |metric| metric_json(metric) },
        commit_log: commit_log_json
      }
    end

    def caveat
      "Public GitHub commit pace and builder activity only; this does not measure true productivity."
    end

    def tracked_builder_summary
      TrackedGithubBuilder.active.group(:cohort).count
    end

    def representative_metrics_week
      return unless @latest_week
      return @latest_week unless boundary_week_partial?

      GithubBuilderIndexWeek.where("week_start_date < ?", @latest_week).recent.first&.week_start_date || @latest_week
    end

    def boundary_week_partial?
      return false unless @latest_week && @observed_through_date

      @observed_through_date < @latest_week + 6.days
    end

    def commit_log_ranges
      return [] unless @builder_metrics_week

      GithubCommitRange
        .where(week_start_date: Github::BuilderWeeklyAggregator::REPORT_START_DATE..@builder_metrics_week)
        .recent
        .to_a
        .select { |range| range.week_start_date.saturday? }
    end

    def commit_log_rows
      return [] if @commit_log_ranges.blank?

      caches = GithubBuilderCommitRangeCache
        .where(github_commit_range_id: @commit_log_ranges.map(&:id))
        .index_by { |cache| [cache.tracked_github_builder_id, cache.github_commit_range_id] }
      recent_totals = GithubBuilderCommitRangeCache
        .where(github_commit_range_id: @commit_log_ranges.map(&:id))
        .group(:tracked_github_builder_id)
        .sum(:commits_count)

      ranked_active_builders(recent_totals).first(@builder_limit).map do |builder|
        {
          builder: builder,
          caches_by_range_id: @commit_log_ranges.to_h do |range|
            [range.id, caches[[builder.id, range.id]]]
          end
        }
      end
    end

    def overview_summary
      total_index_weeks = report_index_weeks.size
      complete_index_weeks = report_index_weeks.count(&:complete?)
      latest_complete_week = report_index_weeks.find(&:complete?)

      {
        active_builders_count: TrackedGithubBuilder.active.count,
        active_repos_count: TrackedGithubBuilderRepo.active.count,
        commit_observations_count: GithubCommitObservation.count,
        weekly_metrics_count: report_weekly_metrics_count,
        index_weeks_count: total_index_weeks,
        complete_index_weeks_count: complete_index_weeks,
        incomplete_index_weeks_count: total_index_weeks - complete_index_weeks,
        latest_complete_week_start_date: latest_complete_week&.week_start_date,
        latest_observed_commit_at: GithubCommitObservation.maximum(:committed_at),
        last_index_update_at: report_index_weeks.filter_map(&:updated_at).max
      }
    end

    def builder_rollups
      recent_totals = if @commit_log_ranges.present?
        GithubBuilderCommitRangeCache
          .where(github_commit_range_id: @commit_log_ranges.map(&:id))
          .group(:tracked_github_builder_id)
          .sum(:commits_count)
      else
        {}
      end
      latest_metrics_by_login = @builder_metrics.index_by(&:github_login)

      ranked_active_builders(recent_totals).first(@builder_limit).map do |builder|
        observations = GithubCommitObservation.for_login(builder.github_login)
        metrics = GithubBuilderWeeklyMetric.where(github_login: builder.github_login)
        {
          builder: builder,
          latest_metric: latest_metrics_by_login[builder.github_login],
          active_repos_count: builder.tracked_github_builder_repos.active.size,
          observations_count: observations.count,
          metric_weeks_count: metrics.count,
          complete_metric_weeks_count: metrics.complete.count,
          latest_commit_at: observations.maximum(:committed_at)
        }
      end
    end

    def ranked_active_builders(recent_totals)
      TrackedGithubBuilder.active.includes(:tracked_github_builder_repos).to_a.sort_by do |builder|
        [-recent_totals.fetch(builder.id, 0).to_i, builder.cohort, builder.github_login]
      end
    end

    def report_index_weeks
      @report_index_weeks ||= GithubBuilderIndexWeek
        .where(week_start_date: Github::BuilderWeeklyAggregator::REPORT_START_DATE..)
        .recent
        .to_a
        .select { |week| week.week_start_date.saturday? }
    end

    def report_weekly_metrics_count
      GithubBuilderWeeklyMetric
        .where(week_start_date: Github::BuilderWeeklyAggregator::REPORT_START_DATE..)
        .pluck(:week_start_date)
        .count(&:saturday?)
    end

    def index_week_json(week)
      {
        week_start_date: week.week_start_date,
        ai_builder_multiple: week.ai_builder_multiple,
        control_builder_multiple: week.control_builder_multiple,
        difficulty_adjusted_ai_builder_multiple: week.difficulty_adjusted_ai_builder_multiple,
        ai_builder_count: week.ai_builder_count,
        control_builder_count: week.control_builder_count,
        complete: week.complete?,
        notes: week.notes
      }
    end

    def metric_json(metric)
      {
        week_start_date: metric.week_start_date,
        github_login: metric.github_login,
        cohort: metric.cohort,
        commits_count: metric.commits_count,
        non_merge_commits_count: metric.non_merge_commits_count,
        bot_adjusted_commits_count: metric.bot_adjusted_commits_count,
        active_repos_count: metric.active_repos_count,
        trailing_90d_avg_weekly_commits: metric.trailing_90d_avg_weekly_commits,
        builder_multiple: metric.builder_multiple,
        bot_adjusted_builder_multiple: metric.bot_adjusted_builder_multiple
      }
    end

    def commit_log_json
      {
        ranges: @commit_log_ranges.map do |range|
          {
            id: range.id,
            week_start_date: range.week_start_date,
            week_end_date: range.week_end_date,
            label: range.display_label
          }
        end,
        rows: @commit_log_rows.map do |row|
          builder = row[:builder]
          {
            github_login: builder.github_login,
            display_name: builder.display_label,
            cohort: builder.cohort,
            ranges: @commit_log_ranges.map do |range|
              cache = row[:caches_by_range_id][range.id]
              {
                range_id: range.id,
                commits_count: cache&.commits_count,
                non_merge_commits_count: cache&.non_merge_commits_count,
                bot_adjusted_commits_count: cache&.bot_adjusted_commits_count,
                active_repos_count: cache&.active_repos_count,
                cached: cache.present?
              }
            end
          }
        end
      }
    end
  end
end
