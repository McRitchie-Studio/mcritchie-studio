require "test_helper"

# ShellHelper's shell rules, on markup alone: the layout's one main, and the
# navbar left to the engine's own one-h1 rule.
class ShellHelperTest < ActionView::TestCase
  include ShellHelper

  test "a page with its own main is seen, and one without is not" do
    assert page_main?('<main class="studio-survey">Q1</main>')
    assert page_main?("<main>Q1</main>")

    refute page_main?('<div class="main-column">main</div><mainframe>'), "control: a class, text or longer tag is no main"
    refute page_main?(nil)
  end

  # The engine decides the brand's heading (studio-engine 0.136.0); the hub
  # passes it no brand_heading, so a forced true or false cannot override it.
  test "the navbar gets no brand_heading: the engine decides the page's one h1" do
    refute_includes navbar_locals.keys, :brand_heading
  end

  private

  def logged_in? = false

  # Calls hub_navbar and returns the locals it hands the engine's navbar.
  def navbar_locals
    calls = []
    stub(:render, ->(partial, **locals) { calls << [ partial, locals ] && "" }) { hub_navbar }
    partial, locals = calls.sole
    assert_equal "layouts/navbar", partial
    locals
  end
end
