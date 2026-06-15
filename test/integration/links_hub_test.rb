require "test_helper"

class LinksHubTest < ActionDispatch::IntegrationTest
  test "public /links renders the general hub for anyone (no auth)" do
    get links_path
    assert_response :success
    assert_select "h1", "Links"
    assert_match "Dashboard", response.body
    # general hub must NOT expose the on-chain console
    assert_no_match "Signing Console", response.body
  end

  test "navbar link sidebar renders the public link tree for anonymous visitors" do
    get links_path
    assert_response :success
    assert_select "button[data-link-sidebar-trigger][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "#studio-link-sidebar a[href=?]", dashboard_path
    assert_select "#studio-link-sidebar a[href=?]", admin_signing_requests_path, count: 0
  end

  test "anonymous visitor cannot reach /admin/links" do
    get admin_links_path
    assert_response :redirect # require_authentication bounces anon
  end

  test "logged-in non-admin is redirected from /admin/links" do
    log_in_as users(:viewer)
    get admin_links_path
    assert_redirected_to root_path # require_admin -> root with "Not authorized"
  end

  test "admin sees the admin hub with the on-chain Signing Console link" do
    log_in_as users(:alex) # role: admin
    get admin_links_path
    assert_response :success
    assert_select "h1", "Admin Links"
    assert_select "a[href=?]", admin_dashboard_path
    assert_match "Signing Console", response.body
    assert_select "a[href=?]", admin_signing_requests_path
  end

  test "logged-in identity controls toggle the admin link sidebar" do
    log_in_as users(:alex)
    get dashboard_path
    assert_response :success
    assert_select "button[data-link-sidebar-trigger][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "button[data-username-display][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "button[data-profile-image-toggle][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "#studio-link-sidebar a[href=?]", admin_signing_requests_path
  end
end
