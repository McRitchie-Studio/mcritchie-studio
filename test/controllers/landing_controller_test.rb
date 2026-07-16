require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  test "landing page renders for anonymous visitors" do
    get root_path

    assert_response :success
  end

  test "landing page renders corrected hero and about copy" do
    get root_path

    assert_response :success
    assert_includes response.body, "supercharge your team"
    assert_includes response.body, "Ten years' experience"
  end

  test "get in touch section shows only the full-width video chat card" do
    get root_path

    assert_response :success
    assert_includes response.body, "Chat Over Video"
    assert_not_includes response.body, "Chat Right Now"
  end

  test "pwa manifest renders the corrected app name" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "McRitchie Studio", manifest["name"]
    assert_equal "McRitchie Studio.", manifest["description"]
  end
end
