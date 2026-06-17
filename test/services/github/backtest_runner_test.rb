require "test_helper"

class Github::BacktestRunnerTest < ActiveSupport::TestCase
  FakeFetcher = Struct.new(:calls, :fail_logins) do
    def fetch_for_builder(builder:, start_date:, end_date:)
      calls << { login: builder.github_login, start_date: start_date, end_date: end_date }
      raise Github::Client::HttpError, "secondary rate limit" if fail_logins.include?(builder.github_login)

      { strategy: "fake", stored: 1 }
    end
  end

  RateLimitedFetcher = Struct.new(:calls) do
    def fetch_for_builder(builder:, start_date:, end_date:)
      calls << { login: builder.github_login, start_date: start_date, end_date: end_date }
      raise Github::Client::RateLimitError, "rate limited" if calls.one?

      { strategy: "fake", stored: 1 }
    end
  end

  FakeAggregator = Struct.new(:count) do
    def aggregate!(start_date:, end_date:)
      count
    end
  end

  FakeCalculator = Struct.new(:count) do
    def calculate!(start_date:, end_date:)
      count
    end
  end

  FakeExporter = Struct.new(:paths) do
    def export!(start_date:, end_date:)
      paths
    end
  end

  test "filters fetches to requested github logins" do
    TrackedGithubBuilder.create!(github_login: "first-builder", cohort: "ai_builder")
    TrackedGithubBuilder.create!(github_login: "second-builder", cohort: "control_builder")
    fetcher = FakeFetcher.new([], [])

    result = runner(fetcher: fetcher).run!(
      start_date: Date.new(2026, 1, 5),
      end_date: Date.new(2026, 1, 11),
      github_logins: "first-builder"
    )

    assert_equal ["first-builder"], fetcher.calls.map { |call| call[:login] }
    assert_equal ["first-builder"], result[:fetch_results].keys
  end

  test "captures per-builder fetch failures and continues" do
    TrackedGithubBuilder.create!(github_login: "rate-limited", cohort: "ai_builder")
    fetcher = FakeFetcher.new([], ["rate-limited"])

    result = runner(fetcher: fetcher).run!(
      start_date: Date.new(2026, 1, 5),
      end_date: Date.new(2026, 1, 11)
    )

    assert_equal "failed", result.dig(:fetch_results, "rate-limited", :strategy)
    assert_includes result.dig(:fetch_results, "rate-limited", :error), "secondary rate limit"
    assert_equal 1, result[:weekly_metrics_count]
    assert_equal 1, result[:index_weeks_count]
  end

  test "can skip fetching and only recalculate stored observations" do
    TrackedGithubBuilder.create!(github_login: "skip-fetch", cohort: "ai_builder")
    fetcher = FakeFetcher.new([], [])

    result = runner(fetcher: fetcher).run!(
      start_date: Date.new(2026, 1, 5),
      end_date: Date.new(2026, 1, 11),
      skip_fetch: true
    )

    assert_empty fetcher.calls
    assert result[:fetch_skipped]
    assert_equal 1, result[:weekly_metrics_count]
  end

  test "can fetch without baseline warmup" do
    TrackedGithubBuilder.create!(github_login: "exact-window", cohort: "ai_builder")
    fetcher = FakeFetcher.new([], [])

    result = runner(fetcher: fetcher).run!(
      start_date: Date.new(2026, 1, 3),
      end_date: Date.new(2026, 1, 9),
      fetch_warmup_days: 0
    )

    assert_equal Date.new(2026, 1, 3), result[:fetch_start_date]
    assert_equal Date.new(2026, 1, 3), fetcher.calls.first[:start_date]
  end

  test "sleeps between builders when configured" do
    TrackedGithubBuilder.create!(github_login: "first-builder", cohort: "ai_builder")
    TrackedGithubBuilder.create!(github_login: "second-builder", cohort: "control_builder")
    sleeps = []
    fetcher = FakeFetcher.new([], [])

    runner(fetcher: fetcher, sleeper: ->(seconds) { sleeps << seconds }, builder_pause_seconds: 2).run!(
      start_date: Date.new(2026, 1, 3),
      end_date: Date.new(2026, 1, 9),
      fetch_warmup_days: 0
    )

    assert_equal [2], sleeps
  end

  test "retries rate limits after configured pause" do
    TrackedGithubBuilder.create!(github_login: "rate-limited", cohort: "ai_builder")
    sleeps = []
    fetcher = RateLimitedFetcher.new([])

    result = runner(
      fetcher: fetcher,
      sleeper: ->(seconds) { sleeps << seconds },
      rate_limit_pause_seconds: 5,
      rate_limit_retries: 1
    ).run!(
      start_date: Date.new(2026, 1, 3),
      end_date: Date.new(2026, 1, 9),
      fetch_warmup_days: 0
    )

    assert_equal [5], sleeps
    assert_equal 2, fetcher.calls.size
    assert_equal "fake", result.dig(:fetch_results, "rate-limited", :strategy)
  end

  private

  def runner(fetcher:, sleeper: ->(_seconds) { }, builder_pause_seconds: 0, rate_limit_pause_seconds: 60, rate_limit_retries: 1)
    Github::BacktestRunner.new(
      fetcher: fetcher,
      aggregator: FakeAggregator.new(1),
      calculator: FakeCalculator.new(1),
      exporter: FakeExporter.new({ weekly_metrics: "weekly.csv" }),
      logger: nil,
      sleeper: sleeper,
      builder_pause_seconds: builder_pause_seconds,
      rate_limit_pause_seconds: rate_limit_pause_seconds,
      rate_limit_retries: rate_limit_retries
    )
  end
end
