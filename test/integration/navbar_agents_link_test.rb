require "test_helper"

# Component-tier guard for the global navbar (desktop + mobile sub-navbar in
# application.html.erb): the "Agents" item must land on /agents, not the old
# activity-feed route.
class NavbarAgentsLinkTest < ActionDispatch::IntegrationTest
  test "navbar links Agents to the agents index on both desktop and mobile" do
    get links_path
    assert_response :success

    agents_links = [
      css_select("[data-test='desktop-agents-nav-link']").first,
      css_select("[data-test='mobile-agents-nav-link']").first
    ]
    assert agents_links.all?,
      "expected the agents link in both the desktop nav and the mobile sub-navbar"
    agents_links.each do |link|
      assert_equal agents_path, link["href"]
      assert_equal "Agents", link.text.strip,
        "navbar agents link should read 'Agents'"
    end

    assert_empty css_select("[data-test$='agents-nav-link'][href=\"#{activities_path}\"]"),
      "the Agents navbar item must not point at /activities"
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
