require "test_helper"

# ShellHelper's heading rule, on markup alone: the brand is a page's h1 only
# when the page has none of its own.
class ShellHelperTest < ActionView::TestCase
  include ShellHelper

  BRAND = '<a href="/"><h1 class="nav-title font-extrabold min-w-0"><span>McRitchie</span><span>Studio</span></h1></a>'.html_safe

  test "a page with its own h1 is seen, and one without is not" do
    assert page_heading?('<header><h1 class="text-2xl">Stages</h1></header>')
    assert page_heading?("<h1>Stages</h1>")

    refute page_heading?("<h2>Tasks</h2><header>h1</header>"), "control: an h2, or the letters h1 in text, is no h1"
    refute page_heading?(nil)
  end

  test "the brand is redrawn as a div and keeps its classes and its words" do
    redrawn = brand_without_heading(BRAND)

    assert_equal '<a href="/"><div class="nav-title font-extrabold min-w-0"><span>McRitchie</span><span>Studio</span></div></a>', redrawn
    assert_predicate redrawn, :html_safe?
  end

  test "only the brand's h1 is redrawn" do
    other = '<h1 class="text-2xl">Stages</h1>'.html_safe

    assert_equal other, brand_without_heading(other), "control: an h1 that is not the brand is left alone"
  end
end
