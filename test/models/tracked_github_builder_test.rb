require "test_helper"

class TrackedGithubBuilderTest < ActiveSupport::TestCase
  FakeFetcher = Struct.new(:calls) do
    def fetch_for_builder(builder:, start_date:, end_date:)
      calls << { builder: builder, start_date: start_date, end_date: end_date }
      { strategy: "fake", stored: 1 }
    end
  end

  StoringFetcher = Struct.new(:calls, :sha, :committed_at) do
    def fetch_for_builder(builder:, start_date:, end_date:)
      calls << { builder: builder, start_date: start_date, end_date: end_date }
      GithubCommitObservation.create!(
        github_login: builder.github_login,
        repo_full_name: "example/cache",
        sha: sha,
        author_login: builder.github_login,
        committer_login: builder.github_login,
        authored_at: committed_at,
        committed_at: committed_at,
        message: "Cache visible weekly public build velocity",
        html_url: "https://github.com/example/cache/commit/#{sha}",
        is_merge: false,
        is_bot: false,
        source_strategy: "search",
        raw_payload: {}
      )
      { strategy: "search", stored: 1 }
    end
  end

  test "fetches common commit windows for a tracked builder" do
    builder = TrackedGithubBuilder.create!(github_login: "Window-Builder", cohort: "ai_builder")
    fetcher = FakeFetcher.new([])

    assert_equal({ strategy: "fake", stored: 1 }, builder.current_week_commits(fetcher: fetcher, today: Date.new(2026, 6, 15)))
    assert_equal Date.new(2026, 6, 13), fetcher.calls.first[:start_date]
    assert_equal Date.new(2026, 6, 15), fetcher.calls.first[:end_date]

    builder.last_week_commits(fetcher: fetcher, today: Date.new(2026, 6, 15))
    assert_equal Date.new(2026, 6, 6), fetcher.calls.second[:start_date]
    assert_equal Date.new(2026, 6, 12), fetcher.calls.second[:end_date]

    builder.last_year_commits(fetcher: fetcher, today: Date.new(2026, 6, 15))
    assert_equal Date.new(2025, 6, 14), fetcher.calls.third[:start_date]
    assert_equal Date.new(2026, 6, 12), fetcher.calls.third[:end_date]

    builder.last_five_commits(fetcher: fetcher, today: Date.new(2026, 6, 15))
    assert_equal Date.new(2021, 7, 24), fetcher.calls.fourth[:start_date]
    assert_equal Date.new(2026, 6, 12), fetcher.calls.fourth[:end_date]
  end

  test "class helpers fetch by github login" do
    TrackedGithubBuilder.create!(github_login: "helper-builder", cohort: "ai_builder")
    fetcher = FakeFetcher.new([])

    TrackedGithubBuilder.last_week_commits("HELPER-BUILDER", fetcher: fetcher, today: Date.new(2026, 6, 15))

    assert_equal "helper-builder", fetcher.calls.first[:builder].github_login
    assert_equal Date.new(2026, 6, 6), fetcher.calls.first[:start_date]
    assert_equal Date.new(2026, 6, 12), fetcher.calls.first[:end_date]
  end

  test "commit window helpers refresh dashboard range cache" do
    builder = TrackedGithubBuilder.create!(github_login: "cache-builder", cohort: "ai_builder")
    fetcher = StoringFetcher.new([], "cache123", Time.utc(2026, 6, 14, 12))

    result = builder.current_week_commits(fetcher: fetcher, today: Date.new(2026, 6, 15))

    assert_equal({ strategy: "search", stored: 1 }, result)
    assert_equal Date.new(2026, 6, 13), fetcher.calls.first[:start_date]
    assert_equal Date.new(2026, 6, 15), fetcher.calls.first[:end_date]

    range = GithubCommitRange.find_by!(week_start_date: Date.new(2026, 6, 13))
    cache = GithubBuilderCommitRangeCache.find_by!(
      tracked_github_builder: builder,
      github_commit_range: range
    )
    assert_equal Date.new(2026, 6, 19), range.week_end_date
    assert_equal 1, cache.commits_count
    assert_equal 1, cache.non_merge_commits_count
    assert_equal 1, cache.bot_adjusted_commits_count
    assert_equal ["cache123"], cache.commit_shas

    metric = GithubBuilderWeeklyMetric.find_by!(
      github_login: builder.github_login,
      week_start_date: Date.new(2026, 6, 13)
    )
    assert_equal 1, metric.commits_count
  end
end
