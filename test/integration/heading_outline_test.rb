require "test_helper"
require_relative "../support/navbar_brand"

# A page has one h1. The navbar's brand is the h1 on a page with no heading of
# its own, and a div on a page that brings one (ShellHelper#hub_navbar). The
# brand is the title words or, once the engine draws it, the kit's lockup
# (test/support/navbar_brand.rb).
class HeadingOutlineTest < ActionDispatch::IntegrationTest
  BRAND = NavbarBrand.brand_name

  def h1_texts
    css_select("h1").map { |heading| NavbarBrand.heading_text(heading) }
  end

  test "each board and guide page has one h1" do
    log_in_as users(:alex)

    { tasks_path => BRAND, epics_path => "Epics", stages_path => "Stages", triage_path => "Triage" }.each do |path, title|
      get path
      assert_response :success, path
      assert_equal [ title ], h1_texts, "#{path}: one h1"
      NavbarBrand.assert_drawn(self, message: "#{path}: the brand is still drawn")
    end
  end

  test "the landing page's one h1 is its headline" do
    get root_path
    assert_response :success

    assert_equal 1, h1_texts.size, "the landing page: #{h1_texts.inspect}"
    refute_equal BRAND, h1_texts.first
    NavbarBrand.assert_drawn(self, "div")
  end

  test "the brand is the h1 where the page has none, and a div where it has one" do
    log_in_as users(:alex)

    get tasks_path
    assert_select NavbarBrand.selector("h1"), 1
    assert_select NavbarBrand.selector("div"), 0

    get stages_path
    assert_select NavbarBrand.selector("h1"), 0
    assert_select NavbarBrand.selector("div"), 1
  end

  # The engine partial's brand classes; the div form must keep every one. The
  # lockup's brand tag carries only its own class (engine.css styles it).
  test "the brand drawn as a div keeps the brand's classes" do
    log_in_as users(:alex)

    get stages_path
    if NavbarBrand.wordmark?
      NavbarBrand.assert_drawn(self, "div")
    else
      assert_select "div.nav-title.font-extrabold.text-heading.tracking-tight.min-w-0", { text: NavbarBrand::WORDS, count: 1 }
    end
  end
end
