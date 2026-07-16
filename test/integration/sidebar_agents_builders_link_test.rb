require "test_helper"

# Guards the nav → sidebar move (application.html.erb + link_tree_helper.rb):
# "Agents" and "Builders" no longer live in the global navbar. Signed-in users
# reach them from the links sidebar's Studio section, pointing at /agents and
# /builders — never the old activity-feed route.
class SidebarAgentsBuildersLinkTest < ActionDispatch::IntegrationTest
  test "global navbar no longer carries the Agents or Builders links" do
    get links_path
    assert_response :success

    assert_empty css_select("[data-test='desktop-agents-nav-link']"),
      "Agents should be gone from the desktop navbar"
    assert_empty css_select("[data-test='mobile-agents-nav-link']"),
      "Agents should be gone from the mobile sub-navbar"
  end

  test "signed-in sidebar links Agents and Builders to their index pages" do
    log_in_as users(:alex)
    get dashboard_path
    assert_response :success

    assert_select "#studio-link-sidebar a[href=?]", agents_path
    assert_select "#studio-link-sidebar a[href=?]", builders_path
    # the Agents item must not regress to the old /activities route
    assert_select "#studio-link-sidebar a[href=?]", activities_path, count: 0
  end

  test "the old 'Meet the Agents' copy is gone" do
    get links_path
    assert_response :success
    assert_no_match(/Meet the Agents/, response.body)
  end

  test "public activities page redirects to agents" do
    get activities_path

    assert_redirected_to agents_path
  end
end
