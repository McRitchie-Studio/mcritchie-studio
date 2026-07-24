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

  test "get in touch section shows only the full-width video chat card" do
    get root_path

    assert_response :success
    assert_includes response.body, "Chat Over Video"
    assert_not_includes response.body, "Chat Right Now"
  end

  test "contact section links to the correct social profiles" do
    get root_path

    assert_response :success
    assert_select "a[href=?]", "https://www.linkedin.com/in/amcritchie/"
    assert_select "a[href=?]", "https://x.com/mcritchiealex"
    # the stale "alexmcritchie" handles must not come back
    assert_select "a[href*=?]", "alexmcritchie", count: 0
  end

  test "pwa manifest renders the corrected app name" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "McRitchie Studio", manifest["name"]
    assert_equal "McRitchie Studio.", manifest["description"]
  end
end
