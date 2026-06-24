require "test_helper"

# Component-tier guard for the ui-only nav copy change: the activities link in
# the global navbar (desktop + mobile sub-navbar in application.html.erb) reads
# "Agents", not the old "Meet the Agents 🦞". A public page is enough — the nav
# links render unconditionally, regardless of auth.
class NavbarAgentsLinkTest < ActionDispatch::IntegrationTest
  test "navbar labels the activities link 'Agents' on both desktop and mobile" do
    get links_path
    assert_response :success

    agents_links = css_select("a[href=\"#{activities_path}\"]")
    assert_equal 2, agents_links.size,
      "expected the activities link in both the desktop nav and the mobile sub-navbar"
    agents_links.each do |link|
      assert_equal "Agents", link.text.strip,
        "navbar activities link should read 'Agents'"
    end
  end

  test "the old 'Meet the Agents' copy is gone" do
    get links_path
    assert_response :success
    assert_no_match(/Meet the Agents/, response.body)
  end
end
