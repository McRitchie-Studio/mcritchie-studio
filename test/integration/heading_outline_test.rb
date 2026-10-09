require "test_helper"

# A page has one h1. The navbar's brand is the h1 on a page with no heading of
# its own, and a div on a page that brings one (ShellHelper#hub_navbar).
class HeadingOutlineTest < ActionDispatch::IntegrationTest
  BRAND = "McRitchieStudio".freeze

  def h1_texts
    css_select("h1").map { |heading| heading.text.squish }
  end

  test "each board and guide page has one h1" do
    log_in_as users(:alex)

    { tasks_path => BRAND, epics_path => "Epics", stages_path => "Stages", triage_path => "Triage" }.each do |path, title|
      get path
      assert_response :success, path
      assert_equal [ title ], h1_texts, "#{path}: one h1"
      assert_select ".nav-title", { text: BRAND, count: 1 }, "#{path}: the brand is still drawn"
    end
  end

  test "the landing page's one h1 is its headline" do
    get root_path
    assert_response :success

    assert_equal 1, h1_texts.size, "the landing page: #{h1_texts.inspect}"
    refute_equal BRAND, h1_texts.first
    assert_select "div.nav-title", text: BRAND, count: 1
  end

  test "the brand is the h1 where the page has none, and a div where it has one" do
    log_in_as users(:alex)

    get tasks_path
    assert_select "h1.nav-title", 1
    assert_select "div.nav-title", 0

    get stages_path
    assert_select "h1.nav-title", 0
    assert_select "div.nav-title", 1
  end
end
