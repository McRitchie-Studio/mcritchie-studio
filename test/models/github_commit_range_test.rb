require "test_helper"

class GithubCommitRangeTest < ActiveSupport::TestCase
  test "normalizes any date in a week to the Monday-Sunday range" do
    range = GithubCommitRange.create!(week_start_date: Date.new(2026, 6, 14))

    assert_equal Date.new(2026, 6, 8), range.week_start_date
    assert_equal Date.new(2026, 6, 14), range.week_end_date
    assert_equal "Jun 8 - Jun 14", range.label
  end

  test "finds an existing range by normalized week start" do
    range = GithubCommitRange.for_week_start(Date.new(2026, 6, 8))

    assert_equal range, GithubCommitRange.for_week_start(Date.new(2026, 6, 14))
    assert_equal 1, GithubCommitRange.where(week_start_date: Date.new(2026, 6, 8)).count
  end
end
