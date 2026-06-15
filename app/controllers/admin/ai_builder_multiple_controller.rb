module Admin
  class AiBuilderMultipleController < ApplicationController
    before_action :require_admin

    def index
      limit = [[params.fetch(:limit, 12).to_i, 1].max, 52].min
      index_weeks = GithubBuilderIndexWeek.recent.limit(limit)
      latest_week = index_weeks.first&.week_start_date
      latest_metrics = latest_week ? GithubBuilderWeeklyMetric.for_week(latest_week).order(:cohort, :github_login) : []

      render json: {
        data: {
          caveat: "Public GitHub commit pace and builder activity only; this does not measure true productivity.",
          latest_week_start_date: latest_week,
          tracked_builders: tracked_builder_summary,
          index_weeks: index_weeks.map { |week| index_week_json(week) },
          latest_builder_weekly_metrics: latest_metrics.map { |metric| metric_json(metric) }
        }
      }
    end

    private

    def tracked_builder_summary
      TrackedGithubBuilder.active.group(:cohort).count
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
  end
end
