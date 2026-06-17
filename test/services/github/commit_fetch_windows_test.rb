require "test_helper"

class Github::CommitFetchWindowsTest < ActiveSupport::TestCase
  test "returns Saturday-Friday UTC fetch windows" do
    today = Date.new(2026, 6, 15)

    assert_equal Date.new(2026, 6, 13)..Date.new(2026, 6, 15), Github::CommitFetchWindows.current_week(today: today)
    assert_equal Date.new(2026, 6, 6)..Date.new(2026, 6, 12), Github::CommitFetchWindows.last_week(today: today)
    assert_equal Date.new(2025, 6, 14)..Date.new(2026, 6, 12), Github::CommitFetchWindows.last_year(today: today)
    assert_equal Date.new(2021, 7, 24)..Date.new(2026, 6, 12), Github::CommitFetchWindows.last_five_years(today: today)
  end
end
