require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  test "dashboard requires admin" do
    get admin_dashboard_path
    assert_response :redirect

    log_in_as @viewer
    get admin_dashboard_path
    assert_redirected_to root_path
  end

  test "admin sees quick links plus users and request log tables" do
    log = ErrorLog.capture!(RuntimeError.new("Synthetic request failure"))
    log.update!(target_type: "MagicLink", target_name: "request")

    log_in_as @admin
    get admin_dashboard_path

    assert_response :success
    assert_select "h1", "Admin Dashboard"
    assert_select "a[href=?]", "#admin-users"
    assert_select "a[href=?]", "#request-logs"
    assert_select "a[href=?]", admin_models_path
    assert_select "a[href=?]", tasks_path, text: /Tasks/
    assert_select "a[href=?]", deployments_path, text: /Deployments/
    assert_select "a[href=?]", stages_path
    assert_select "a[href=?]", history_builders_path, text: /Builder History/
    assert_select "a[href=?]", nfl_hub_path
    assert_match "NFL Hub", response.body
    assert_select "a[href=?]", admin_links_path
    assert_select "table#admin-users-table"
    assert_select "table#admin-users-table.sticky-data-table"
    assert_select "table#admin-users-table[data-sticky-table-header]"
    assert_select "div[data-sticky-table-scroll] table#admin-users-table"
    assert_select "section#admin-users[class*='scroll-mt-']"
    assert_select "table#request-logs-table"
    assert_match @admin.email, response.body
    assert_match "Synthetic request failure", response.body
    assert_select "a[href=?]", error_log_path(log)
  end

  test "the dashboard opens with four cards that lead to their pages" do
    log_in_as @admin
    get admin_dashboard_path

    assert_select "[data-test='stat-cards'] a", 4
    assert_select "a[data-test='stat-card-users'][href=?]", admin_model_path("users")
    assert_select "a[data-test='stat-card-agents'][href=?]", agents_path
    assert_select "a[data-test='stat-card-applications'][href=?]", applications_path
    assert_select "a[data-test='stat-card-users']", text: /#{User.count}/
    assert_select "a[data-test='stat-card-sessions']"
  end
end
