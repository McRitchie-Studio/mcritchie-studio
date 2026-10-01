require "test_helper"

# /about is the studio's public company page, linked from the footer.
class AboutPageTest < ActionDispatch::IntegrationTest
  test "a visitor can read the about page without signing in" do
    get about_path

    assert_response :success
    assert_select "title", "About · McRitchie Studio"
    assert_select "h1", "McRitchie Studio"
    assert_select "h2", text: "Software"
    assert_select "h2", text: "Marketing"
    assert_select "h2", text: "How we work"
    assert_select "ol li", 3
    assert_select "a[href='#{schedule_index_path}']", text: "Schedule a call"
    assert_select "a[href='#{packages_path}']", text: "See packages"
  end

  test "the footer's About link lands on it" do
    get root_path

    assert_select "footer[data-site-footer] a[href='#{about_path}']", text: "About"
  end
end
