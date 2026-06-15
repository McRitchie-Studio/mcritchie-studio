require "test_helper"

class Github::BacktestRunnerTest < ActiveSupport::TestCase
  FakeFetcher = Struct.new(:calls, :fail_logins) do
    def fetch_for_builder(builder:, start_date:, end_date:)
      calls << { login: builder.github_login, start_date: start_date, end_date: end_date }
      raise Github::Client::HttpError, "secondary rate limit" if fail_logins.include?(builder.github_login)

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

  private

  def runner(fetcher:)
    Github::BacktestRunner.new(
      fetcher: fetcher,
      aggregator: FakeAggregator.new(1),
      calculator: FakeCalculator.new(1),
      exporter: FakeExporter.new({ weekly_metrics: "weekly.csv" }),
      logger: nil
    )
  end
end
