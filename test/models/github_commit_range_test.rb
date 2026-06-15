require "test_helper"

class GithubCommitRangeTest < ActiveSupport::TestCase
  test "normalizes any date in a week to the Saturday-Friday UTC range" do
    range = GithubCommitRange.create!(week_start_date: Date.new(2026, 6, 14))

    assert_equal Date.new(2026, 6, 13), range.week_start_date
    assert_equal Date.new(2026, 6, 19), range.week_end_date
    assert_equal "Jun 19, 2026", range.label
  end

  test "finds an existing range by normalized week start" do
    range = GithubCommitRange.for_week_start(Date.new(2026, 6, 13))

    assert_equal range, GithubCommitRange.for_week_start(Date.new(2026, 6, 14))
    assert_equal 1, GithubCommitRange.where(week_start_date: Date.new(2026, 6, 13)).count
  end
end
