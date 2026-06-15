require "test_helper"

class Admin::ModelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  test "models overview requires admin" do
    get admin_models_path
    assert_response :redirect

    log_in_as @viewer
    get admin_models_path
    assert_redirected_to root_path
  end

  test "admin sees overview modules with links to all model pages" do
    log_in_as @admin
    get admin_models_path

    assert_response :success
    assert_select "h1", "Models"
    assert_select "table#models-users-table"
    assert_select "table#models-teams-table"
    assert_select "table#models-arenas-table"
    assert_select "a[href=?]", admin_model_path("users")
    assert_select "a[href=?]", admin_model_path("teams")
    assert_select "a[href=?]", admin_model_path("arenas")
    assert_match @admin.email, response.body
    assert_match "Buffalo Bills", response.body
    assert_match "Highmark Stadium", response.body
  end

  test "admin can browse users model page" do
    log_in_as @admin
    get admin_model_path("users")

    assert_response :success
    assert_select "h1", "Users"
    assert_select "table#models-users-table"
    assert_match @admin.email, response.body
  end

  test "admin can browse teams model page" do
    log_in_as @admin
    get admin_model_path("teams")

    assert_response :success
    assert_select "h1", "Teams"
    assert_select "table#models-teams-table"
    assert_match "Buffalo Bills", response.body
    assert_match "Highmark Stadium", response.body
  end

  test "admin can browse arenas model page" do
    log_in_as @admin
    get admin_model_path("arenas")

    assert_response :success
    assert_select "h1", "Arenas"
    assert_select "table#models-arenas-table"
    assert_match "Highmark Stadium", response.body
    assert_match "1 Bills Drive", response.body
  end

  test "model pages are paginated" do
    30.times do |index|
      Arena.create!(
        name: "Fixture Arena #{index.to_s.rjust(2, '0')}",
        address: "#{index} Test Way",
        location: "Test City, TS",
        country: "USA",
        timezone: "America/New_York"
      )
    end

    log_in_as @admin
    get admin_model_path("arenas", page: 2)

    assert_response :success
    assert_select "h1", "Arenas"
    assert_match "Page 2 of 2", response.body
    assert_select "a[href=?]", admin_model_path("arenas", page: 1), text: "Previous"
    assert_match "Fixture Arena", response.body
  end

  test "unknown model key returns not found" do
    log_in_as @admin
    get admin_model_path("contracts")

    assert_response :not_found
  end
end
