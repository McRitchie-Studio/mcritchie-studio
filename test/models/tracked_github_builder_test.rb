require "test_helper"

class TrackedGithubBuilderTest < ActiveSupport::TestCase
  FakeFetcher = Struct.new(:calls) do
    def fetch_for_builder(builder:, start_date:, end_date:)
      calls << { builder: builder, start_date: start_date, end_date: end_date }
      { strategy: "fake", stored: 1 }
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
end
