# frozen_string_literal: true

require "test_helper"

# [component] The application layout's document shell: every page says its
# language and has exactly one main landmark, around the page and not the header
# or footer (axe html-has-lang, landmark-one-main, region;
# lane-ui-infrastructure P1).
class LayoutLandmarksTest < ActionDispatch::IntegrationTest
  # The home page and /about are full width (content_for :full_width); /packages
  # takes the padded column. Both arms of the layout are covered.
  PAGES = { "/" => :full_width, "/packages" => :column, "/about" => :full_width }.freeze

  PAGES.each do |path, arm|
    test "#{path} (#{arm}) renders html lang en and one main around the page" do
      get path
      assert_response :success

      assert_select "html[lang=en]", 1
      assert_select "main", 1
      assert_select "header main, main header.nav-shell, footer main", 0, "main wraps the page, not the shell"
      assert_select "body > main", 1
      if arm == :column
        assert_select "main > div.max-w-7xl", 1
      else
        assert_select "main > div.max-w-7xl", 0
      end
    end
  end

  # The bar stack (the environment bar off production, impersonation) is outside
  # the header and main, so it rides in a labelled region; with no bar there is
  # no empty landmark.
  test "every status bar sits in the Site status region, and no bar means no region" do
    get "/about"
    bars = css_select("[data-studio-bar-stack]").size
    assert_equal bars, css_select("[role=region][aria-label='Site status'] [data-studio-bar-stack]").size
    assert_equal [ bars, 1 ].min, css_select("[role=region][aria-label='Site status']").size

    Studio.stub(:show_environment_banner?, false) { get "/about" }
    assert_select "[data-studio-bar-stack]", 0
    assert_select "[role=region][aria-label='Site status']", 0
  end

  test "the home hero's main holds the hero" do
    get "/"
    assert_select "main section picture img[data-hero-image]", 1
  end
end
