class BuildersController < ApplicationController
  skip_before_action :require_authentication, only: [:index]

  RANGE_LIMIT = 4

  def index
    @language = params.fetch(:language, "Ruby")
    @ranges = recent_commit_ranges
    @builders = Builder.active.includes(:person).where(primary_language: @language).to_a
    @builder_rows = builder_rows
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
end
