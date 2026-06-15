require "test_helper"

class Github::BuilderHistoryBatchRunnerTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 6, 15)

  FakeFetcher = Struct.new(:calls) do
    def fetch_for_builder(builder:, start_date:, end_date:, after_segment: nil)
      calls << { login: builder.github_login, start_date: start_date, end_date: end_date }
      after_segment&.call(start_date, [start_date + 6.days, end_date].min)
      { strategy: "fake", stored: 1 }
    end
  end

  FailingFetcher = Struct.new(:calls) do
    def fetch_for_builder(builder:, start_date:, end_date:, after_segment: nil)
      calls << { login: builder.github_login, start_date: start_date, end_date: end_date }
      raise Github::Client::HttpError, "secondary rate limit"
    end
  end

  FakeAggregator = Struct.new(:calls) do
    def aggregate!(start_date:, end_date:, github_logins: nil)
      calls << { start_date: start_date, end_date: end_date, github_logins: github_logins }
      1
    end
  end

  test "selects the next incomplete batch and skips complete builders" do
    complete_builder = TrackedGithubBuilder.create!(github_login: "aaa-complete", cohort: "ai_builder")
    incomplete_builder = TrackedGithubBuilder.create!(github_login: "bbb-incomplete", cohort: "ai_builder")
    TrackedGithubBuilder.create!(github_login: "ccc-incomplete", cohort: "control_builder")
    create_complete_cache(complete_builder)
    fetcher = FakeFetcher.new([])
    aggregator = FakeAggregator.new([])

    result = runner(fetcher: fetcher, aggregator: aggregator).run!(today: TODAY, batch_size: 1)

    assert_equal ["bbb-incomplete"], result[:selected_logins]
    assert_equal ["bbb-incomplete"], fetcher.calls.map { |call| call[:login] }
    assert_equal "bbb-incomplete", result[:next_start_after]
    assert_equal 1, result[:remaining_after_batch]
  end

  test "filters by cohort start_after and explicit logins" do
    TrackedGithubBuilder.create!(github_login: "aaa-ai", cohort: "ai_builder")
    TrackedGithubBuilder.create!(github_login: "bbb-control", cohort: "control_builder")
    TrackedGithubBuilder.create!(github_login: "ccc-control", cohort: "control_builder")
    fetcher = FakeFetcher.new([])

    result = runner(fetcher: fetcher).run!(
      today: TODAY,
      batch_size: 10,
      cohort: "control_builder",
      start_after: "bbb-control",
      github_logins: "aaa-ai,ccc-control"
    )

    assert_equal ["ccc-control"], result[:selected_logins]
  end

  test "publishes segment progress before final aggregation" do
    TrackedGithubBuilder.create!(github_login: "segment-builder", cohort: "ai_builder")
    fetcher = FakeFetcher.new([])
    aggregator = FakeAggregator.new([])
    messages = []

    result = runner(
      fetcher: fetcher,
      aggregator: aggregator,
      reporter: ->(message) { messages << message }
    ).run!(today: TODAY, batch_size: 1)

    assert_equal ["segment-builder"], result[:selected_logins]
    assert_equal 2, aggregator.calls.size
    assert_equal "segment-builder", aggregator.calls.first[:github_logins]
    assert_equal Date.new(2021, 7, 24), aggregator.calls.first[:start_date]
    assert_equal Date.new(2021, 7, 30), aggregator.calls.first[:end_date]
    assert_equal Date.new(2021, 7, 24), aggregator.calls.second[:start_date]
    assert_equal Date.new(2026, 6, 12), aggregator.calls.second[:end_date]
    assert messages.any? { |message| message.include?("cached segment 1 login=segment-builder") }
  end

  test "captures fetch failures and continues" do
    TrackedGithubBuilder.create!(github_login: "first-builder", cohort: "ai_builder")
    TrackedGithubBuilder.create!(github_login: "second-builder", cohort: "ai_builder")
    fetcher = FailingFetcher.new([])

    result = runner(fetcher: fetcher).run!(today: TODAY, batch_size: 2)

    assert_equal ["first-builder", "second-builder"], result[:selected_logins]
    assert_equal "failed", result.dig(:results, "first-builder", :strategy)
    assert_equal "failed", result.dig(:results, "second-builder", :strategy)
  end

  private

  def runner(fetcher:, aggregator: FakeAggregator.new([]), reporter: nil)
    Github::BuilderHistoryBatchRunner.new(
      fetcher: fetcher,
      aggregator: aggregator,
      logger: nil,
      sleeper: ->(_seconds) {},
      reporter: reporter
    )
  end

  def create_complete_cache(builder)
    window = Github::CommitFetchWindows.last_five_years(today: TODAY)
    Github::BuilderWeeklyAggregator.week_starts_between(window.begin, window.end).each do |week_start|
      GithubBuilderCommitRangeCache.create!(
        tracked_github_builder: builder,
        github_commit_range: GithubCommitRange.for_week_start(week_start),
        github_login: builder.github_login,
        cohort: builder.cohort,
        commits_count: 0,
        cached_at: Time.current
      )
    end
  end
end
