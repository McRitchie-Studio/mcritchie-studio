require "csv"
require "test_helper"

class Github::BacktestCsvExporterTest < ActiveSupport::TestCase
  setup do
    @output_dir = Rails.root.join("tmp", "ai_builder_multiple_test_#{SecureRandom.hex(6)}")
  end

  teardown do
    FileUtils.rm_rf(@output_dir)
  end

  test "exports weekly metrics, range caches, index weeks, and commit observation sample" do
    week_start = Date.new(2026, 6, 1)
    builder = TrackedGithubBuilder.create!(
      github_login: "builder",
      cohort: "ai_builder",
      display_name: "Builder"
    )
    range = GithubCommitRange.for_week_start(week_start)
    GithubBuilderWeeklyMetric.create!(
      github_login: "builder",
      cohort: "ai_builder",
      week_start_date: week_start,
      commits_count: 2,
      non_merge_commits_count: 2,
      bot_adjusted_commits_count: 1,
      active_repos_count: 1,
      trailing_90d_avg_weekly_commits: 1,
      builder_multiple: 2,
      bot_adjusted_builder_multiple: 1
    )
    GithubBuilderIndexWeek.create!(
      week_start_date: week_start,
      ai_builder_multiple: 2,
      control_builder_multiple: 1,
      difficulty_adjusted_ai_builder_multiple: 2,
      ai_builder_count: 5,
      control_builder_count: 5
    )
    GithubBuilderCommitRangeCache.create!(
      tracked_github_builder: builder,
      github_commit_range: range,
      github_login: "builder",
      cohort: "ai_builder",
      commits_count: 2,
      non_merge_commits_count: 2,
      bot_adjusted_commits_count: 1,
      active_repos_count: 1,
      trailing_90d_avg_weekly_commits: 1,
      builder_multiple: 2,
      bot_adjusted_builder_multiple: 1,
      commit_shas: ["abc123"],
      cached_at: Time.current
    )
    GithubCommitObservation.create!(
      github_login: "builder",
      repo_full_name: "owner/repo",
      sha: SecureRandom.hex(20),
      committed_at: week_start,
      source_strategy: "repo_scoped",
      raw_payload: {}
    )

    paths = Github::BacktestCsvExporter.new(output_dir: @output_dir).export!(
      start_date: week_start,
      end_date: week_start + 6
    )

    assert_equal Github::BacktestCsvExporter::WEEKLY_COLUMNS, CSV.read(paths[:weekly_metrics]).first
    assert_equal Github::BacktestCsvExporter::RANGE_CACHE_COLUMNS, CSV.read(paths[:range_caches]).first
    assert_equal Github::BacktestCsvExporter::INDEX_COLUMNS, CSV.read(paths[:index_weeks]).first
    assert_equal Github::BacktestCsvExporter::SAMPLE_COLUMNS, CSV.read(paths[:commit_observations_sample]).first
  end
end
