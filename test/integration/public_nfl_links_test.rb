require "test_helper"

# task public-nfl-cards-stay-public: the public NFL pages must not send a visitor
# into the admin wall. Every same-site link a visitor is shown on /nfl and /links
# has to resolve to an action AdminWall::PUBLIC names, or the visitor clicks
# through to a sign-in page they can never get past.
class PublicNflLinksTest < ActionDispatch::IntegrationTest
  test "[component] every link on /nfl a visitor sees leads to a public page" do
    get nfl_hub_path
    assert_response :success

    assert_select "a[href=?]", teams_path, count: 0
    assert_select "a[href=?]", people_path, count: 0
    assert_select "a[href=?]", nfl_rosters_path, minimum: 1
    assert_all_links_public
  end

  test "[component] an admin still gets the Teams and People cards on /nfl" do
    log_in_as users(:alex)
    get nfl_hub_path
    assert_response :success

    assert_select "a[href=?]", teams_path
    assert_select "a[href=?]", people_path
  end

  test "[component] /links shows its public NFL section to a visitor" do
    get links_path
    assert_response :success

    assert_select "a[href=?]", nfl_hub_path, minimum: 1
    assert_select "a[href=?]", games_season_path(2026), minimum: 1
    assert_select "a[href=?]", teams_path, count: 0
    assert_select "a[href=?]", people_path, count: 0
    assert_all_links_public
  end

  test "[component] an admin's /links keeps the Directory with Teams and People" do
    log_in_as users(:alex)
    get links_path
    assert_response :success

    assert_select "a[href=?]", nfl_hub_path
    assert_select "a[href=?]", teams_path
    assert_select "a[href=?]", people_path
  end

  private

  # Every href on the page that is a path into this app must be one a visitor may
  # open. A path the router cannot place (an OmniAuth door, an asset) is skipped:
  # it never reaches a controller behind the wall.
  def assert_all_links_public
    hrefs = css_select("a[href]").map { |a| a["href"] }.select { |href| href.start_with?("/") && !href.start_with?("//") }.uniq
    assert hrefs.any?, "precondition: the page renders same-site links"

    walled = hrefs.filter_map do |href|
      route = Rails.application.routes.recognize_path(href.split(/[?#]/).first, method: :get)
      href unless AdminWall.public?(route[:controller], route[:action])
    rescue ActionController::RoutingError
      nil
    end

    assert_empty walled, "a visitor is linked to walled pages: #{walled.join(', ')}"
  end
end
