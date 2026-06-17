require "test_helper"

class DevopsControllerTest < ActionDispatch::IntegrationTest
  test "index requires login" do
    get devops_path

    assert_redirected_to login_path
  end

  test "index requires admin" do
    log_in_as users(:viewer)

    get devops_path

    assert_redirected_to root_path
  end

  test "admin can view test suite catalog" do
    log_in_as users(:alex)

    get devops_path

    assert_response :success
    assert_select "h2", "DevOps Test Suites"
    assert_select "h3", "McRitchie Studio"
    assert_select "h3", "Turf Monster"
    assert_includes response.body, "QA devnet mutating smoke"
  end
end
