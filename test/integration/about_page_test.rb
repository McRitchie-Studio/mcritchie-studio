require "test_helper"

# Alex McRitchie's about page moved to alex.build on 2026-11-06 (task
# hub-drops-about-section). The hub keeps no about page: its old address is a
# permanent redirect there, and the footer links there directly.
class AboutPageTest < ActionDispatch::IntegrationTest
  ALEX_BUILD_ABOUT = "https://alex.build/about"

  test "[integration] /about is a 301 to alex.build/about" do
    get "/about"

    assert_response :moved_permanently
    assert_equal ALEX_BUILD_ABOUT, response.location
  end

  test "[integration] /about redirects a signed-in viewer too, with no page of its own" do
    log_in_as users(:alex)
    get "/about"

    assert_response :moved_permanently
    assert_equal ALEX_BUILD_ABOUT, response.location
    refute Rails.application.routes.named_routes.key?(:about), "no about_path helper to link the hub's own address"
  end

  test "[integration] the footer's About link goes straight to alex.build/about" do
    get root_path

    assert_select "footer[data-site-footer] a[href='#{ALEX_BUILD_ABOUT}']", text: "About", count: 1
    assert_select "a[href='/about']", 0, "nothing links the redirect"
  end
end
