require "test_helper"

class LinksHubTest < ActionDispatch::IntegrationTest
  test "public /links shows only the Apps section behind the session wall" do
    get links_path
    assert_response :success
    assert_select "h1", "Links"
    assert_match "Turf Monster", response.body
    # Studio/NFL/Directory links are walled off until sign-in
    assert_select "a[href=?]", dashboard_path, count: 0
  end

  test "anonymous link sidebar exposes only the public Apps section" do
    get links_path
    assert_response :success
    assert_select "button[data-link-sidebar-trigger][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    # Apps (satellites) stays public; the emoji-swap proves the Turf Monster link rendered
    assert_select "#studio-link-sidebar .studio-emoji-swap"
    # Studio is behind the session wall
    assert_select "#studio-link-sidebar a[href=?]", dashboard_path, count: 0
  end

  test "link sidebar panel renders the slide-in transition markup" do
    get links_path
    assert_response :success
    # The panel must slide in from off-screen right (translate-x-full -> translate-x-0),
    # not pop into place. Guards against a re-removal of the transition (see #33,
    # which stripped it to fix a browser-back snapshot bug).
    assert_match 'x-transition:enter-start="translate-x-full"', response.body
    assert_match 'x-transition:enter-end="translate-x-0"', response.body
    assert_match 'x-transition:leave-end="translate-x-full"', response.body
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

  test "admin sees the admin hub" do
    log_in_as users(:alex) # role: admin
    get admin_links_path
    assert_response :success
    assert_select "h1", "Admin Links"
    assert_select "a[href=?]", admin_dashboard_path
    # The hub's only On-chain link was the Signing Console, and the section went
    # with it (/tasks/retire-signing-console). Turf Monster is the web3 hub, so
    # this one must not grow back.
    assert_no_match "Signing Console", response.body
  end

  test "logged-in identity controls toggle the admin link sidebar" do
    log_in_as users(:alex)
    get dashboard_path
    assert_response :success
    assert_select "button[data-link-sidebar-trigger][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "button[data-username-display][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "button[data-profile-image-toggle][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "#studio-link-sidebar .studio-emoji-swap-hover"
  end
end
