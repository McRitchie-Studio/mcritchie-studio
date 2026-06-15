module Admin
  class AiBuilderMultipleController < ApplicationController
    before_action :require_admin

    def index
      @limit = [[params.fetch(:limit, 26).to_i, 1].max, 52].min
      @index_weeks = GithubBuilderIndexWeek.recent.limit(@limit).to_a
      @chart_weeks = @index_weeks.reverse
      @latest_week = @index_weeks.first&.week_start_date
      @latest_metrics = @latest_week ? GithubBuilderWeeklyMetric.for_week(@latest_week).order(:cohort, :github_login).to_a : []
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
        latest_builder_weekly_metrics: @latest_metrics.map { |metric| metric_json(metric) }
      }
    end

    def caveat
      "Public GitHub commit pace and builder activity only; this does not measure true productivity."
    end

    def tracked_builder_summary
      TrackedGithubBuilder.active.group(:cohort).count
    end

    def overview_summary
      total_index_weeks = GithubBuilderIndexWeek.count
      complete_index_scope = GithubBuilderIndexWeek
        .where.not(ai_builder_multiple: nil)
        .where.not(control_builder_multiple: nil)
        .where.not(difficulty_adjusted_ai_builder_multiple: nil)
      complete_index_weeks = complete_index_scope.count
      latest_complete_week = complete_index_scope.recent.first

      {
        active_builders_count: TrackedGithubBuilder.active.count,
        active_repos_count: TrackedGithubBuilderRepo.active.count,
        commit_observations_count: GithubCommitObservation.count,
        weekly_metrics_count: GithubBuilderWeeklyMetric.count,
        index_weeks_count: total_index_weeks,
        complete_index_weeks_count: complete_index_weeks,
        incomplete_index_weeks_count: total_index_weeks - complete_index_weeks,
        latest_complete_week_start_date: latest_complete_week&.week_start_date,
        latest_observed_commit_at: GithubCommitObservation.maximum(:committed_at),
        last_index_update_at: GithubBuilderIndexWeek.maximum(:updated_at)
      }
    end

    def builder_rollups
      latest_metrics_by_login = @latest_metrics.index_by(&:github_login)

      TrackedGithubBuilder.active.includes(:tracked_github_builder_repos).order(:cohort, :github_login).map do |builder|
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
