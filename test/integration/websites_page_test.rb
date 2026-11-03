# frozen_string_literal: true

require "test_helper"

# [integration] /websites: the public page of apps built on Studio.
class WebsitesPageTest < ActionDispatch::IntegrationTest
  test "a signed-out visitor sees a card per app" do
    get websites_path
    assert_response :success

    assert_select "h1", text: "Websites Built on Studio", count: 1
    assert_select "[data-test='websites-grid'] [data-test='build-example']", count: BuildGallery.examples.size
  end

  test "the logged-out sidebar is one line per link, with Sign In, Chat and one Apps link" do
    get websites_path

    panel = "#studio-link-sidebar"
    assert_select "#{panel} a", text: /Sign In/, count: 1
    assert_select "#{panel} a[href='#{build_path}']", text: /Chat/, count: 1
    assert_select "#{panel} a[href='#{build_path}'] img[src*='alex']", count: 1
    assert_select "#{panel} a[href='#{websites_path}']", text: /Websites Built on Studio/, count: 1
    assert_select "#{panel} a span.text-xs", count: 0
    assert_select "#{panel} a", text: /Turf Monster/, count: 0
  end
end
