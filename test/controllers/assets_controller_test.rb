# frozen_string_literal: true

require "test_helper"

# [integration] GET /assets — admin-only, reading the test env's fixture
# listing (config/initializers/asset_browser.rb), never a live bucket.
class AssetsControllerTest < ActionDispatch::IntegrationTest
  test "a visitor who is not signed in is sent to log in" do
    get asset_browser_path

    assert_redirected_to "/login"
  end

  test "a signed-in non-admin is refused" do
    log_in_as users(:viewer)
    get asset_browser_path

    assert_redirected_to root_path
  end

  test "the root shows the top-level folders and root objects" do
    log_in_as users(:alex)
    get asset_browser_path

    assert_response :success
    assert_select "[data-test='asset-folder']", 2
    assert_select "[data-test='asset-file'][data-key='readme.txt']"
    assert_select "[data-test='asset-store']", /fixture/
  end

  test "a folder shows breadcrumbs back to the root and its own contents" do
    log_in_as users(:alex)
    get asset_browser_path(prefix: "music_videos/drake/hotline_bling/")

    assert_equal %w[Root music_videos drake], css_select("[data-test='asset-breadcrumbs'] a").map { |a| a.text.strip }
    assert_select "[data-test='asset-breadcrumbs'] [aria-current='page']", "hotline_bling"
    assert_select "[data-test='asset-folder']", 3
    assert_select "[data-test='asset-file'][data-key='music_videos/drake/hotline_bling/notes.txt']"
  end

  test "a traversal prefix reads as the root" do
    log_in_as users(:alex)
    get asset_browser_path(prefix: "../etc/")

    assert_select "[data-test='asset-folder']", 2
  end

  test "search finds names across folders and states its bound" do
    log_in_as users(:alex)
    get asset_browser_path(q: "hotline")

    assert_select "[data-test='asset-file']", 2
    assert_select "[data-test='asset-search-bound']", /Searched all 7 objects/
  end

  test "a selected clip previews as video beside the listing" do
    log_in_as users(:alex)
    key = "music_videos/drake/hotline_bling/clips/hotline_bling_clip_01_chorus_vertical_0045_0102.mp4"
    get asset_browser_path(prefix: "music_videos/drake/hotline_bling/clips/", key: key)

    assert_select "[data-test='asset-preview'] video[src*='X-Amz-Signature']"
    assert_select "[data-test='asset-file'][aria-current='true'][data-key=?]", key
  end

  test "a missing key says so instead of failing" do
    log_in_as users(:alex)
    get asset_browser_path(key: "nope.mp4")

    assert_response :success
    assert_select "[data-test='asset-preview-missing']"
  end

  test "a store that cannot answer renders a notice, not a 500" do
    log_in_as users(:alex)
    broken = Object.new
    def broken.label = "s3 · mcritchie-studio-dev"
    def broken.list(**) = raise(AssetBrowser::Unavailable, "AccessDenied")

    AssetBrowser.stub(:source, broken) { get asset_browser_path }

    assert_response :success
    assert_select "[data-test='asset-unavailable']", /AccessDenied/
  end
end
