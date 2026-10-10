require "test_helper"

# ShellHelper's heading rule, on markup alone: the brand is a page's h1 only
# when the page has none of its own.
class ShellHelperTest < ActionView::TestCase
  include ShellHelper

  test "a page with its own h1 is seen, and one without is not" do
    assert page_heading?('<header><h1 class="text-2xl">Stages</h1></header>')
    assert page_heading?("<h1>Stages</h1>")

    refute page_heading?("<h2>Tasks</h2><header>h1</header>"), "control: an h2, or the letters h1 in text, is no h1"
    refute page_heading?(nil)
  end

  # The engine reads brand_heading with fetch(…, true) and a truthiness test, so
  # nil would draw a div: the local must be a real boolean.
  test "the navbar gets brand_heading false on a page with its own h1 and true otherwise" do
    assert_same false, navbar_locals(page_html: '<h1 class="text-2xl">Stages</h1>')[:brand_heading]
    assert_same true, navbar_locals(page_html: "<h2>Tasks</h2>")[:brand_heading]
    assert_same true, navbar_locals(page_html: nil)[:brand_heading]
  end

  private

  def logged_in? = false

  # Calls hub_navbar and returns the locals it hands the engine's navbar.
  def navbar_locals(page_html:)
    calls = []
    stub(:render, ->(partial, **locals) { calls << [ partial, locals ] && "" }) { hub_navbar(page_html: page_html) }
    partial, locals = calls.sole
    assert_equal "layouts/navbar", partial
    locals
  end
end
