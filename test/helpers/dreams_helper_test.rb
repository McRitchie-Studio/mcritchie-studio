# frozen_string_literal: true

require "test_helper"

# [unit] dream_story_html: a dream's story drops its title, renders Markdown, and
# never turns a javascript: link into a clickable href.
# [unit] dream_count_tag: the active/idle colour follows the FILTERED count.
class DreamsHelperTest < ActionView::TestCase
  test "a javascript: link in a story is text, not an href" do
    html = dream_story_html("# Title\n\nSee [the note](javascript:alert(1)) and [docs](/docs).")

    links = Nokogiri::HTML.fragment(html).css("a").map { |a| a["href"] }
    assert_equal [ "/docs" ], links
    assert_includes html, "javascript:alert(1)"
    assert_not_includes html, "<h1>"
  end

  test "a count tag is highlighted only while its filtered count is above zero" do
    styled = ->(filter) do
      html = dream_count_tag(%w[approved approved], filter, class: "badge", active_class: "on-a on-b", idle_class: "off")
      Nokogiri::HTML.fragment(html).at("span")
    end

    all = styled.call("all")
    assert_equal "2 dreams", all.text
    assert_equal %w[badge on-a on-b], all["class"].split
    assert_equal [ "on-a on-b", "off" ], [ all["data-dream-count-active"], all["data-dream-count-idle"] ]

    proposed = styled.call("proposed")
    assert_equal "0 dreams", proposed.text
    assert_equal %w[badge off], proposed["class"].split, "a zero under the filter is not highlighted"
  end

  test "a count tag without colours carries no colour attributes" do
    span = Nokogiri::HTML.fragment(dream_count_tag(%w[approved], nil, class: "x")).at("span")

    assert_equal "x", span["class"]
    assert_nil span["data-dream-count-active"]
  end

  # The SOP list as the page renders it. No dream in the fixture bank tags an SOP,
  # so the partial is rendered directly with one SOP carrying two approved dreams.
  test "an SOP badge under Proposed reads 0 dreams and is not highlighted" do
    sop = DreamOrgChart::Sop.new(invocation: "pr-review", kind: "sop", doc_path: "agents/carl/sops/pr-review",
                                 summary: "", dream_count: 2, dream_statuses: %w[approved approved])
    badge = lambda do |filter|
      @filter = filter
      Nokogiri::HTML.fragment(render(partial: "dreams/sops", locals: { sops: [ sop ], label: "SOPs" }))
                    .at("[data-test='sop-dream-count']")
    end

    all = badge.call("all")
    assert_equal "2 dreams", all.text
    assert_includes all["class"].split, "bg-primary/10"

    proposed = badge.call("proposed")
    assert_equal "0 dreams", proposed.text
    assert_not_includes proposed["class"].split, "bg-primary/10", "a zero under Proposed still looks highlighted"
    assert_includes proposed["class"].split, "bg-surface-alt"
  end
end
