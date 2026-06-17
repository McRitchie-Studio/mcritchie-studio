class BuildersController < ApplicationController
  skip_before_action :require_authentication, only: [:index, :history]

  RANGE_LIMIT = 13

  def index
    @language = params[:language].presence
    @ranges = recent_commit_ranges
    @builders = builders_scope.to_a
    @builder_rows = builder_rows
    @normalized_scores_by_cache_id = normalized_scores_by_cache_id
  end

  def history
    @language = params[:language].presence
    @builders = builders_scope.to_a
    @report = Github::BuilderCommitHistoryReport.new(builders: @builders).build
    @chart_quarters = @report.chart_quarters
    @chart_max_value = [
      @report.rows.flat_map { |row| @chart_quarters.map { |quarter| row[:quarter_totals][quarter.key].to_i } }.max.to_i,
      1
    ].max
  end

  private

  def recent_commit_ranges
    GithubCommitRange
      .where(week_start_date: Github::BuilderWeeklyAggregator::REPORT_START_DATE..)
      .recent
      .to_a
      .select { |range| range.week_start_date.saturday? }
      .first(RANGE_LIMIT)
  end

  def builders_scope
    scope = Builder.active.included_in_roster.includes(:person)
    @language.present? ? scope.where(primary_language: @language) : scope
  end

  def builder_rows
    return [] if @builders.blank?

    tracked_by_login = TrackedGithubBuilder
      .where(github_login: @builders.map(&:github_login))
      .index_by(&:github_login)
    caches_by_key = if @ranges.any? && tracked_by_login.any?
      GithubBuilderCommitRangeCache
        .where(tracked_github_builder_id: tracked_by_login.values.map(&:id), github_commit_range_id: @ranges.map(&:id))
        .index_by { |cache| [cache.tracked_github_builder_id, cache.github_commit_range_id] }
    else
      {}
    end

    @builders.map do |builder|
      tracked = tracked_by_login[builder.github_login]
      range_caches = @ranges.to_h do |range|
        [range.id, tracked ? caches_by_key[[tracked.id, range.id]] : nil]
      end
      {
        builder: builder,
        tracked_builder: tracked,
        caches_by_range_id: range_caches,
        trailing_commits_count: range_caches.values.compact.sum(&:commits_count)
      }
    end.sort_by { |row| [-row[:trailing_commits_count], row[:builder].display_name.downcase, row[:builder].github_login] }
  end

  def normalized_scores_by_cache_id
    caches = @builder_rows.flat_map { |row| row[:caches_by_range_id].values }.compact
    history_end_date = @ranges.first&.week_start_date || Date.current
    Github::BuilderCommitNormalizer.new(history_end_date: history_end_date).scores_for(caches: caches)
  end
end
