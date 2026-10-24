# frozen_string_literal: true

require "test_helper"

# [unit] SafeMarkdown: the /docs and /dreams Markdown renderer leaves a link with
# an unsafe scheme (javascript:, data:, vbscript:, …) as literal text, never an
# href, while relative site links and http(s)/mailto links still render.
class SafeMarkdownTest < ActiveSupport::TestCase
  def hrefs(html) = Nokogiri::HTML.fragment(html).css("a").map { |a| a["href"] }

  test "a javascript: link renders as text, in any case or spacing" do
    [ "[x](javascript:alert(1))", "[x](JaVaScRiPt:alert(1))", "[x]( javascript:alert(1))",
      "[x](javascript:alert(1) \"title\")", "<javascript:alert(1)>" ].each do |markdown|
      html = SafeMarkdown.render(markdown)
      assert_empty hrefs(html), "#{markdown.inspect} rendered a link: #{html}"
      assert_includes html.downcase, "javascript:", "the text stays visible"
    end
  end

  test "other unsafe schemes and images render no URL" do
    [ "[d](data:text/html,hi)", "[v](vbscript:msgbox(1))" ].each do |markdown|
      assert_empty hrefs(SafeMarkdown.render(markdown)), markdown
    end
    assert_empty Nokogiri::HTML.fragment(SafeMarkdown.render("![i](javascript:alert(1))")).css("img")
  end

  test "relative, anchor, http(s), mailto and autolinks still render" do
    html = SafeMarkdown.render(<<~MD)
      [role](../agents/pokemon/role.md) [top](#top) [site](/docs) [ext](https://example.com?a=1&b=2 "T")
      [mail](mailto:a@example.com) and https://example.org and b@example.com
    MD
    assert_equal [ "../agents/pokemon/role.md", "#top", "/docs", "https://example.com?a=1&b=2",
                   "mailto:a@example.com", "https://example.org", "mailto:b@example.com" ], hrefs(html)
    assert_includes html, 'title="T"'
  end

  test "raw HTML is still filtered" do
    assert_empty hrefs(SafeMarkdown.render('<a href="javascript:alert(1)">raw</a>'))
  end

  test "safe_url? reads the scheme the way a browser does" do
    assert SafeMarkdown.safe_url?("role.md")
    assert SafeMarkdown.safe_url?("HTTPS://example.com")
    refute SafeMarkdown.safe_url?("java\nscript:alert(1)")
    refute SafeMarkdown.safe_url?("\tjavascript:alert(1)")
  end

  test "images: false (the chat) renders a Markdown image as a link, so nothing loads without a click" do
    html = SafeMarkdown.render("Look ![chart](https://evil.example/x.png?q=secret) and ![](https://evil.example/y.png)", images: false)

    assert_not_includes html, "<img"
    assert_equal [ "https://evil.example/x.png?q=secret", "https://evil.example/y.png" ], hrefs(html)
    assert_includes html, ">chart</a>"
    assert_includes html, ">image</a>"
    assert_includes SafeMarkdown.render("![a](https://example.com/a.png)"), "<img", "the docs pages still draw images"
    assert_not_includes SafeMarkdown.render("![a](javascript:alert(1))", images: false), "href"
  end

  def anchors(html) = Nokogiri::HTML.fragment(html).css("a").to_h { |a| [ a["href"], [ a["target"], a["rel"] ] ] }

  test "[unit] new_tab: an off-site link opens in a new tab with rel noopener; hub links stay in the tab" do
    html = SafeMarkdown.render(<<~MD, images: false, new_tab: true)
      **[table-ready.mcritchie.app](https://table-ready.mcritchie.app/)** and https://other.example/x
      [proto](//evil.example/y) [home](https://www.example.com/applications) [bare](http://example.com/docs)
      [path](/applications/x/chat) [top](#top) [mail](mailto:a@example.com) ![pic](https://evil.example/p.png)
    MD

    assert_equal({ "https://table-ready.mcritchie.app/" => [ "_blank", "noopener" ],
                   "https://other.example/x" => [ "_blank", "noopener" ],
                   "//evil.example/y" => [ "_blank", "noopener" ],
                   "https://www.example.com/applications" => [ nil, nil ],
                   "http://example.com/docs" => [ nil, nil ],
                   "/applications/x/chat" => [ nil, nil ],
                   "#top" => [ nil, nil ],
                   "mailto:a@example.com" => [ nil, nil ],
                   "https://evil.example/p.png" => [ "_blank", "nofollow noopener noreferrer" ] }, anchors(html))
  end

  test "[unit] without new_tab (docs, dreams) no link gains a target" do
    html = SafeMarkdown.render("[x](https://other.example/) https://other.example/y", images: false)
    assert_equal [ [ nil, nil ], [ nil, nil ] ], anchors(html).values
  end

  test "[unit] new_tab adds only target and rel: raw HTML attributes are still filtered" do
    html = SafeMarkdown.render('<a href="https://other.example/" target="_self" onclick="x()">raw</a> [ok](https://other.example/)', new_tab: true)
    links = Nokogiri::HTML.fragment(html).css("a")
    assert_equal 1, links.size, html
    assert_equal %w[href rel target], links.first.attributes.keys.sort
  end
end
