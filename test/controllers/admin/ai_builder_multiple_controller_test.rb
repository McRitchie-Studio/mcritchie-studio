require "test_helper"

class Admin::AiBuilderMultipleControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
  end

  test "index requires authentication" do
    get admin_ai_builder_multiple_path(format: :json)

    assert_response :unauthorized
  end

  test "index returns latest index data and builder metrics" do
    log_in_as(@admin)
    week_start = create_backtest_snapshot

    get admin_ai_builder_multiple_path(format: :json)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Public GitHub commit pace and builder activity only; this does not measure true productivity.", body.dig("data", "caveat")
    assert_equal "2026-06-06", body.dig("data", "latest_week_start_date")
    assert_equal 1, body.dig("data", "index_weeks").size
    assert_equal 1, body.dig("data", "latest_builder_weekly_metrics").size
    assert_equal "Jun 12, 2026", body.dig("data", "commit_log", "ranges", 0, "label")
    builder_row = body.dig("data", "commit_log", "rows").find { |row| row["github_login"] == "builder" }
    assert_equal 2, builder_row.dig("ranges", 0, "commits_count")
  end

  test "index renders dashboard html" do
    log_in_as(@admin)
    create_backtest_snapshot

    get admin_ai_builder_multiple_path

    assert_response :success
    assert_select "h1", "AI Builder Multiple"
    assert_select "h2", "Published Multiples"
    assert_select "h2", "Weekly Commit Log"
    assert_select "h2", "Latest Full Builder Weekly Metrics"
    assert_select "h2", "Tracked Builders"
    assert_select "th", "Jun 12"
    assert_no_match "Jun 6 - Jun 12", response.body
    assert_select "p", /does not measure true productivity/
    assert_select "a[href=?]", "#commit-log", "Commit Log"
    assert_select "a[href=?]", "#tracked-builders", "Tracked Builders"
    assert_select "a[href=?]", "https://github.com/builder", "@builder"
    assert_select "a[href=?]", "https://github.com/example/repo", "example/repo"
    assert_select "a[href=?]", admin_ai_builder_multiple_path(format: :json), "JSON"
  end

  test "index limits commit log rows by recent activity" do
    log_in_as(@admin)
    week_start = create_backtest_snapshot
    low_activity_builder = TrackedGithubBuilder.create!(
      github_login: "quiet-builder",
      cohort: "control_builder",
      active: true
    )
    GithubBuilderCommitRangeCache.create!(
      tracked_github_builder: low_activity_builder,
      github_commit_range: GithubCommitRange.for_week_start(week_start),
      github_login: low_activity_builder.github_login,
      cohort: low_activity_builder.cohort,
      commits_count: 0,
      cached_at: Time.current
    )

    get admin_ai_builder_multiple_path(format: :json, builder_limit: 1)

    assert_response :success
    rows = JSON.parse(response.body).dig("data", "commit_log", "rows")
    assert_equal 1, rows.size
    assert_equal "builder", rows.first["github_login"]
  end

  private

  def create_backtest_snapshot
    week_start = Date.new(2026, 6, 6)
    builder = TrackedGithubBuilder.create!(github_login: "builder", cohort: "ai_builder", active: true)
    builder.tracked_github_builder_repos.create!(repo_full_name: "example/repo", active: true)
    GithubCommitObservation.create!(
      github_login: "builder",
      repo_full_name: "example/repo",
      sha: "abc123",
      committed_at: week_start.to_time,
      source_strategy: "repo_scoped"
    )
    GithubBuilderIndexWeek.create!(
      week_start_date: week_start,
      ai_builder_multiple: 2,
      control_builder_multiple: 1,
      difficulty_adjusted_ai_builder_multiple: 2,
      ai_builder_count: 5,
      control_builder_count: 5
    )
    GithubBuilderWeeklyMetric.create!(
      github_login: "builder",
      cohort: "ai_builder",
      week_start_date: week_start,
      commits_count: 2,
      non_merge_commits_count: 2,
      bot_adjusted_commits_count: 2,
      active_repos_count: 1,
      trailing_90d_avg_weekly_commits: 1,
      builder_multiple: 2,
      bot_adjusted_builder_multiple: 2
    )
    range = GithubCommitRange.for_week_start(week_start)
    GithubBuilderCommitRangeCache.create!(
      tracked_github_builder: builder,
      github_commit_range: range,
      github_login: "builder",
      cohort: "ai_builder",
      commits_count: 2,
      non_merge_commits_count: 2,
      bot_adjusted_commits_count: 2,
      active_repos_count: 1,
      trailing_90d_avg_weekly_commits: 1,
      builder_multiple: 2,
      bot_adjusted_builder_multiple: 2,
      commit_shas: ["abc123"],
      cached_at: Time.current
    )
    week_start
  end
end
