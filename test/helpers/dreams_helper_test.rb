# frozen_string_literal: true

require "test_helper"

# [unit] dream_story_html: a dream's story drops its title, renders Markdown, and
# never turns a javascript: link into a clickable href.
class DreamsHelperTest < ActionView::TestCase
  test "a javascript: link in a story is text, not an href" do
    html = dream_story_html("# Title\n\nSee [the note](javascript:alert(1)) and [docs](/docs).")

    links = Nokogiri::HTML.fragment(html).css("a").map { |a| a["href"] }
    assert_equal [ "/docs" ], links
    assert_includes html, "javascript:alert(1)"
    assert_not_includes html, "<h1>"
  end
end
