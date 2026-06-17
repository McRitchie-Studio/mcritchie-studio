require "test_helper"

class Github::BuilderCommitNormalizerTest < ActiveSupport::TestCase
  test "returns nil until there is enough cached history" do
    normalizer = Github::BuilderCommitNormalizer.new(min_history_ranges: 4)

    assert_nil normalizer.score_for(count: 10, history_counts: [1, 2, 3])
  end

  test "maps builder-relative historical percentiles to normalized scores" do
    normalizer = Github::BuilderCommitNormalizer.new(min_history_ranges: 1)
    history = (0...100).to_a

    assert_equal 1, normalizer.score_for(count: 0, history_counts: history)
    assert_equal 2, normalizer.score_for(count: 20, history_counts: history)
    assert_equal 3, normalizer.score_for(count: 40, history_counts: history)
    assert_equal 5, normalizer.score_for(count: 60, history_counts: history)
    assert_equal 8, normalizer.score_for(count: 80, history_counts: history)
  end

  test "scores a zero week low and a new nonzero week high for an all-zero history" do
    normalizer = Github::BuilderCommitNormalizer.new(min_history_ranges: 1)
    history = Array.new(20, 0)

    assert_equal 1, normalizer.score_for(count: 0, history_counts: history)
    assert_equal 8, normalizer.score_for(count: 1, history_counts: history)
  end

  test "scores displayed caches against each builder's own cached history" do
    quiet_builder = TrackedGithubBuilder.create!(github_login: "quiet-builder", cohort: "ai_builder")
    active_builder = TrackedGithubBuilder.create!(github_login: "active-builder", cohort: "ai_builder")

    week_starts = (0...13).map { |index| Date.new(2026, 3, 21) + index.weeks }
    quiet_caches = week_starts.each_with_index.map do |week_start, index|
      create_cache(quiet_builder, week_start, commits_count: index)
    end
    active_caches = week_starts.each_with_index.map do |week_start, index|
      create_cache(active_builder, week_start, commits_count: 100 + index)
    end

    scores = Github::BuilderCommitNormalizer.new(
      history_start_date: week_starts.first,
      history_end_date: week_starts.last,
      min_history_ranges: 13
    ).scores_for(caches: [quiet_caches.last, active_caches.first])

    assert_equal 8, scores[quiet_caches.last.id]
    assert_equal 1, scores[active_caches.first.id]
  end

  private

  def create_cache(builder, week_start, commits_count:)
    GithubBuilderCommitRangeCache.create!(
      tracked_github_builder: builder,
      github_commit_range: GithubCommitRange.for_week_start(week_start),
      github_login: builder.github_login,
      cohort: builder.cohort,
      commits_count: commits_count,
      non_merge_commits_count: commits_count,
      bot_adjusted_commits_count: commits_count,
      active_repos_count: commits_count.positive? ? 1 : 0,
      cached_at: Time.current
    )
  end
end
