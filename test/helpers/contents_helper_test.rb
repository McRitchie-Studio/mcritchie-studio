require "test_helper"

class ContentsHelperTest < ActionView::TestCase
  # Escaping turns an apostrophe into &#39;, and the "#39" inside it is not a tag.
  test "x_post_markup leaves an escaped apostrophe whole and still marks the tags" do
    html = x_post_markup("Can't stop the Bills #nfl <b>")

    assert_includes html, "Can&#39;t stop"
    assert_includes html, %(<span style="color:#1d9bf0">#nfl</span>)
    assert_includes html, "&lt;b&gt;"
    assert_equal 1, html.scan("<span").size
  end
end
