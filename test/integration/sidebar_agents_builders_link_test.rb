require "test_helper"

# "Agents" and "Builders" no longer live in the global navbar, or in the sidebar
# since the Studio section left it (Alex McRitchie, 2026-11-04). An admin reaches
# /agents from the admin dashboard and /builders from the Basement, never the old
# activity-feed route.
class SidebarAgentsBuildersLinkTest < ActionDispatch::IntegrationTest
  test "global navbar no longer carries the Agents or Builders links" do
    get links_path
    assert_response :success

    assert_empty css_select("[data-test='desktop-agents-nav-link']"),
      "Agents should be gone from the desktop navbar"
    assert_empty css_select("[data-test='mobile-agents-nav-link']"),
      "Agents should be gone from the mobile sub-navbar"
  end

  test "the admin dashboard links Agents, the Basement links Builders, and the sidebar links neither" do
    log_in_as users(:alex)
    get admin_dashboard_path
    assert_response :success

    assert_select "a[data-test='stat-card-agents'][href=?]", agents_path
    assert_select "#studio-link-sidebar", 1
    assert_select "#studio-link-sidebar a[href=?]", agents_path, count: 0
    assert_select "#studio-link-sidebar a[href=?]", builders_path, count: 0
    # no link may regress to the retired /activities path
    assert_select "#studio-link-sidebar a[href=?]", "/activities", count: 0

    get admin_basement_path
    assert_select "[data-link-hub] a[href=?]", builders_path
  end

  test "the old 'Meet the Agents' copy is gone" do
    get links_path
    assert_response :success
    assert_no_match(/Meet the Agents/, response.body)
  end
end
