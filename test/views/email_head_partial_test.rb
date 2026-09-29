require "test_helper"

# [unit] broadcasts/_email_head's default hero alt is the title's TEXT: entities
# decoded, markup dropped, and escaped by the attribute. strip_tags alone hands
# back an html_safe String with a raw double quote, which ends the alt early.
class EmailHeadPartialTest < ActionView::TestCase
  def hero_alt_for(title, **locals)
    render partial: "broadcasts/email_head",
           locals: { hero_file: "x.jpg", preheader: "p", title: title, subtitle: "s", **locals }
    render inline: %(<img alt="<%= yield :email_hero_alt %>">)
  end

  test "a title with a quote, an entity and markup becomes safe alt text" do
    html = hero_alt_for(%(Say "hi" &amp; <b>go</b>))
    assert_equal %(Say "hi" & go), Nokogiri::HTML5.fragment(html).at("img")["alt"]
  end

  test "the World Cup titles decode their entities" do
    html = hero_alt_for("&#9917;&nbsp; It&rsquo;s almost here")
    assert_equal "⚽  It’s almost here", Nokogiri::HTML5.fragment(html).at("img")["alt"]
  end

  test "an explicit hero_alt wins" do
    html = hero_alt_for("Title", hero_alt: %(A "board"))
    assert_equal %(A "board"), Nokogiri::HTML5.fragment(html).at("img")["alt"]
  end
end
