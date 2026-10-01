require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  test "landing page renders for anonymous visitors" do
    get root_path

    assert_response :success
  end

  test "landing page renders acquisition-focused hero and about copy" do
    get root_path

    assert_response :success
    # Hero
    assert_includes response.body, "Solutions For"
    assert_includes response.body, "Families"
    assert_includes response.body, "An acquisition entrepreneur partnering with owners"
    # About
    assert_includes response.body, "Acquisition Entrepreneur"
    assert_includes response.body, "Over a decade of operational"
    # Cards
    assert_includes response.body, "Originating and scaling new business"
    assert_includes response.body, "Technical Architecture"
    assert_includes response.body, "Product and engineering design, development"
    # the consultant-era copy must not return
    assert_not_includes response.body, "supercharge your team"
    assert_not_includes response.body, "Ten years' experience"
    assert_not_includes response.body, "Technical Strategy"
  end

  # Was "shows only the full-width video chat card", pinning the "Chat Over
  # Video" heading. That card held the Sprintful widget; the section now holds
  # the Google booking frame and no card heading (/tasks/professional-site-footer).
  test "get in touch section shows the booking frame and no chat card" do
    get root_path

    assert_response :success
    assert_includes response.body, "Get in Touch"
    assert_select "iframe[data-booking-frame]", 1
    assert_not_includes response.body, "Chat Over Video"
    assert_not_includes response.body, "Chat Right Now"
  end

  # The home page's own "Get In Touch" section is gone; the site footer carries
  # these links now, and the same handles are pinned there.
  test "the home page links to the correct social profiles" do
    get root_path

    assert_response :success
    assert_select "a[href=?]", "https://www.linkedin.com/in/amcritchie/"
    assert_select "a[href=?]", "https://x.com/mcritchiealex"
    # The stale "alexmcritchie" LinkedIn and X handles must not come back. Scoped
    # to those two hosts: on Instagram, "alexmcritchie" IS the right handle.
    assert_select "a[href*='linkedin.com'][href*='alexmcritchie']", 0
    assert_select "a[href*='x.com'][href*='alexmcritchie']", 0
    assert_select "a[href*='twitter.com'][href*='alexmcritchie']", 0
  end

  test "pwa manifest renders the corrected app name" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "McRitchie Studio", manifest["name"]
    assert_equal "McRitchie Studio.", manifest["description"]
  end
end
