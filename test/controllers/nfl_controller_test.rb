require "test_helper"

class NflControllerTest < ActionDispatch::IntegrationTest
  test "hub page loads" do
    get nfl_hub_path
    assert_response :success
    assert_select "h1", "NFL Hub"
  end

  test "hub page contains section links" do
    get nfl_hub_path
    assert_response :success
    assert_select "a[href=?]", games_week_path(2025, 1)
    assert_select "a[href=?]", nfl_quarterback_rankings_path
    assert_select "a[href=?]", nfl_offensive_line_rankings_path
    assert_select "a[href=?]", nfl_pass_first_rankings_path
    # Teams and People are admin pages; test/integration/public_nfl_links_test.rb
    # covers both sides of that gate.
    assert_select "a[href=?]", nfl_rosters_path
  end

  test "hub does not require authentication" do
    get nfl_hub_path
    assert_response :success
  end
end
