require "test_helper"

class Github::BuilderWeeklyAggregatorTest < ActiveSupport::TestCase
  setup do
    @builder = TrackedGithubBuilder.create!(
      github_login: "activity-builder",
      cohort: "ai_builder",
      display_name: "Activity Builder"
    )
  end

  test "buckets weeks beginning Monday" do
    assert_equal Date.new(2026, 6, 8), Github::BuilderWeeklyAggregator.week_start_for(Date.new(2026, 6, 14))
    assert_equal Date.new(2026, 6, 15), Github::BuilderWeeklyAggregator.week_start_for(Date.new(2026, 6, 15))
  end

  test "calculates baseline and builder multiple from prior 90 days" do
    week_start = Date.new(2026, 6, 1)
    9.times do |index|
      create_observation(@builder.github_login, committed_at: week_start - 10.days - index.days)
    end
    2.times do |index|
      create_observation(@builder.github_login, committed_at: week_start + index.days)
    end

    Github::BuilderWeeklyAggregator.new.aggregate!(start_date: week_start, end_date: week_start + 6.days)

    metric = GithubBuilderWeeklyMetric.find_by!(github_login: @builder.github_login, week_start_date: week_start)
    assert_in_delta 0.7, metric.trailing_90d_avg_weekly_commits.to_f, 0.0001
    assert_in_delta 2.8571, metric.builder_multiple.to_f, 0.0001
  end

  test "sets builder multiple to nil when baseline is zero" do
    week_start = Date.new(2026, 6, 1)
    create_observation(@builder.github_login, committed_at: week_start)

    Github::BuilderWeeklyAggregator.new.aggregate!(start_date: week_start, end_date: week_start + 6.days)

    metric = GithubBuilderWeeklyMetric.find_by!(github_login: @builder.github_login, week_start_date: week_start)
    assert_equal 0, metric.trailing_90d_avg_weekly_commits
    assert_nil metric.builder_multiple
  end

  test "counts all, non-merge, bot-adjusted commits and active repos" do
    week_start = Date.new(2026, 6, 1)
    create_observation(@builder.github_login, committed_at: week_start - 2.days)
    create_observation(@builder.github_login, committed_at: week_start, repo_full_name: "owner/one")
    create_observation(@builder.github_login, committed_at: week_start + 1.day, repo_full_name: "owner/two", is_merge: true)
    create_observation(@builder.github_login, committed_at: week_start + 2.days, repo_full_name: "owner/two", is_bot: true)

    Github::BuilderWeeklyAggregator.new.aggregate!(start_date: week_start, end_date: week_start + 6.days)

    metric = GithubBuilderWeeklyMetric.find_by!(github_login: @builder.github_login, week_start_date: week_start)
    assert_equal 3, metric.commits_count
    assert_equal 2, metric.non_merge_commits_count
    assert_equal 1, metric.bot_adjusted_commits_count
    assert_equal 2, metric.active_repos_count
  end

  test "caches builder commit counts by explicit weekly range" do
    week_start = Date.new(2026, 6, 8)
    create_observation(@builder.github_login, committed_at: week_start - 7.days)
    first_commit = create_observation(@builder.github_login, committed_at: week_start + 1.day, repo_full_name: "owner/one")
    second_commit = create_observation(@builder.github_login, committed_at: week_start + 2.days, repo_full_name: "owner/two", is_bot: true)

    Github::BuilderWeeklyAggregator.new.aggregate!(start_date: week_start, end_date: week_start + 6.days)

    range = GithubCommitRange.find_by!(week_start_date: week_start)
    cache = GithubBuilderCommitRangeCache.find_by!(
      tracked_github_builder: @builder,
      github_commit_range: range
    )
    assert_equal Date.new(2026, 6, 14), range.week_end_date
    assert_equal "Jun 8 - Jun 14", range.label
    assert_equal 2, cache.commits_count
    assert_equal 2, cache.non_merge_commits_count
    assert_equal 1, cache.bot_adjusted_commits_count
    assert_equal 2, cache.active_repos_count
    assert_equal [first_commit.sha, second_commit.sha], cache.commit_shas
    assert_not_nil cache.cached_at
  end

  test "dedupes overlapping observations with the same sha for a builder" do
    week_start = Date.new(2026, 6, 8)
    duplicate_sha = SecureRandom.hex(20)
    create_observation(
      @builder.github_login,
      committed_at: week_start,
      repo_full_name: "owner/search-repo",
      source_strategy: "search",
      sha: duplicate_sha
    )
    create_observation(
      @builder.github_login,
      committed_at: week_start,
      repo_full_name: "owner/source-repo",
      source_strategy: "repo_scoped",
      sha: duplicate_sha
    )

    Github::BuilderWeeklyAggregator.new.aggregate!(start_date: week_start, end_date: week_start + 6.days)

    cache = GithubBuilderCommitRangeCache.joins(:github_commit_range).find_by!(
      github_login: @builder.github_login,
      github_commit_ranges: { week_start_date: week_start }
    )
    assert_equal 1, cache.commits_count
    assert_equal [duplicate_sha], cache.commit_shas
    assert_equal 1, cache.active_repos_count
  end

  private

  def create_observation(github_login, committed_at:, repo_full_name: "owner/repo", is_merge: false, is_bot: false, source_strategy: "repo_scoped", sha: SecureRandom.hex(20))
    GithubCommitObservation.create!(
      github_login: github_login,
      repo_full_name: repo_full_name,
      sha: sha,
      author_login: github_login,
      committer_login: github_login,
      authored_at: committed_at,
      committed_at: committed_at,
      message: "Change public build velocity adapter",
      html_url: "https://github.com/#{repo_full_name}/commit/#{SecureRandom.hex(20)}",
      is_merge: is_merge,
      is_bot: is_bot,
      source_strategy: source_strategy,
      raw_payload: {}
    )
  end
end
