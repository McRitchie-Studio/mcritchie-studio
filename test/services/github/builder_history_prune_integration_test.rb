require "test_helper"

# Integration: the REAL BuilderWeeklyAggregator over the DB with only the GitHub
# fetch stubbed. Proves the prune runs AFTER aggregation and that real weekly
# metrics — including the trailing-90-day baseline multiple — are computed from
# the raw observations before they are deleted. This is the guard against the
# tempting-but-wrong per-segment delete that would starve the baseline.
class Github::BuilderHistoryPruneIntegrationTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 6, 15)
  TARGET_WEEK = Github::BuilderWeeklyAggregator.week_start_for(Date.new(2026, 5, 20))

  # Mimics CommitFetcher: writes real observation rows, then fires after_segment.
  SeedingFetcher = Struct.new(:rows) do
    def fetch_for_builder(builder:, start_date:, end_date:, after_segment: nil)
      rows.each do |row|
        GithubCommitObservation.create!(
          github_login: builder.github_login,
          repo_full_name: "acme/app",
          sha: row[:sha],
          committed_at: row[:at],
          authored_at: row[:at],
          is_merge: row.fetch(:merge, false),
          source_strategy: "search"
        )
      end
      after_segment&.call(start_date, end_date)
      { strategy: "seed", stored: rows.size }
    end
  end

  test "computes weekly metrics from observations, then prunes the staged rows" do
    builder = TrackedGithubBuilder.create!(github_login: "real-builder", cohort: "ai_builder")
    rows = [
      { sha: "t1", at: Time.utc(2026, 5, 18, 12) },              # target week, non-merge
      { sha: "t2", at: Time.utc(2026, 5, 19, 12) },              # target week, non-merge
      { sha: "tm", at: Time.utc(2026, 5, 20, 12), merge: true }, # target week, merge
      { sha: "b1", at: Time.utc(2026, 4, 1, 12) },               # trailing-90d baseline
      { sha: "b2", at: Time.utc(2026, 3, 15, 12) }               # trailing-90d baseline
    ]

    runner = Github::BuilderHistoryBatchRunner.new(
      fetcher: SeedingFetcher.new(rows),
      aggregator: Github::BuilderWeeklyAggregator.new,
      logger: nil,
      sleeper: ->(_seconds) { }
    )

    result = runner.run!(today: TODAY, batch_size: 1, skip_complete: false)

    metric = GithubBuilderWeeklyMetric.find_by!(github_login: "real-builder", week_start_date: TARGET_WEEK)
    assert_equal 3, metric.commits_count
    assert_equal 2, metric.non_merge_commits_count
    assert metric.builder_multiple.present?, "baseline observations must feed the trailing-90d multiple"
    assert metric.builder_multiple.positive?

    cache = GithubBuilderCommitRangeCache
      .joins(:github_commit_range)
      .find_by!(github_login: "real-builder", github_commit_ranges: { week_start_date: TARGET_WEEK })
    assert_equal %w[t1 t2 tm], cache.commit_shas.sort

    assert_equal 0, GithubCommitObservation.for_login("real-builder").count,
      "observations must be pruned once the full window is cached"
    assert_equal rows.size, result.dig(:results, "real-builder", :pruned_observations)
  end
end
