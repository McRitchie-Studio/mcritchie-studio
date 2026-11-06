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
    assert_select "#{carousel}.carousel-spotlight", count: 1 # the spotlight style: the centred app full size
    assert_select "#{carousel} .carousel-slide[role='group']", count: BuildGallery.examples.size
    BuildGallery.examples.each do |example|
      assert_select "#{carousel} .carousel-slide[aria-label=?] [data-test='build-example']", example.name, count: 1
    end
    # The spotlight opens on the middle app (studio/_carousel start: :middle by default), so
    # both arrows are live and both halves of the row hold an app at load. Its arrows move one slide.
    middle = BuildGallery.examples.size / 2
    assert_select "#{carousel} .carousel-slide[data-current]", count: 1
    assert_select "#{carousel} .carousel-slide[data-current][aria-label=?]", BuildGallery.examples[middle].name, count: 1
    assert_operator middle, :>, 0, "one app has no middle to open on, so this measures nothing"
    assert_select "#{carousel} button[aria-label='Previous slide'][aria-controls='websites-apps'][aria-disabled='false']", count: 1
    assert_select "#{carousel} button[aria-label='Next slide'][aria-controls='websites-apps']", count: 1
    # Next is dead at load only when the middle is also the last app (two apps).
    assert_select "#{carousel} button[aria-label='Next slide'][aria-disabled='true']", count: middle == BuildGallery.examples.size - 1 ? 1 : 0
    assert_select "#{carousel} button.carousel-dot", count: BuildGallery.examples.size
    assert_select "#{carousel} button.carousel-dot[aria-current='true']", count: 1
    assert_select "#{carousel} button.carousel-dot[aria-current='true'][aria-label=?]", "Go to slide #{middle + 1}", count: 1
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
