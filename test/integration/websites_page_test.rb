# frozen_string_literal: true

require "test_helper"

# [integration] /websites: the public page of apps built on Studio.
class WebsitesPageTest < ActionDispatch::IntegrationTest
  # /chat once the wall opens it, /build until then (LinkTreeHelper#visitor_chat_path).
  def chat_href = AdminWall::PUBLIC.fetch("chat", []).include?("index") ? chat_index_path : build_path

  test "a signed-out visitor sees a card per app" do
    get websites_path
    assert_response :success

    assert_select "title", "Portfolio · McRitchie Studio"
    assert_select "h1", text: "Portfolio", count: 1
    assert_select "[data-test='websites-carousel'] [data-test='build-example']", count: BuildGallery.examples.size
  end

  test "the apps ride the engine carousel, a slide per app named for it" do
    get websites_path

    carousel = "section[data-test='websites-carousel'][aria-roledescription='carousel'][aria-label='Live apps']"
    assert_select carousel, count: 1
    assert_select "#{carousel}[data-studio-controller='carousel']", count: 1
    assert_select "#{carousel} .carousel-slide[role='group']", count: BuildGallery.examples.size
    BuildGallery.examples.each do |example|
      assert_select "#{carousel} .carousel-slide[aria-label=?] [data-test='build-example']", example.name, count: 1
    end
    assert_select "#{carousel} button[aria-label='Next slides'][aria-controls='websites-apps']", count: 1
    assert_select "#{carousel} button.carousel-dot", count: BuildGallery.examples.size
    assert_select "[data-test='websites-grid']", count: 0
  end

  test "the logged-out sidebar is one line per link, with Sign In, Chat and one Apps link" do
    get websites_path

    panel = "#studio-link-sidebar"
    assert_select "#{panel} a", text: /Sign In/, count: 1
    assert_select "#{panel} a[href='#{chat_href}']", text: /Chat/, count: 1
    # Chat is Alex's portrait on the drawer and a line icon under the glass style.
    if Studio.respond_to?(:sidebar_style)
      assert_select "#{panel} a[href='#{chat_href}'] [data-sidebar-row-icon] svg", count: 1
    else
      assert_select "#{panel} a[href='#{chat_href}'] img[src*='alex']", count: 1
    end
    assert_select "#{panel} a[href='#{websites_path}']", text: /Portfolio/, count: 1
    assert_select "#{panel} a span.text-xs", count: 0
    assert_select "#{panel} a", text: /Turf Monster/, count: 0
  end
end
