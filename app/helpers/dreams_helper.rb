# frozen_string_literal: true

module DreamsHelper
  # A dream's story body as HTML. Same Redcarpet settings as DocsController, with
  # raw HTML filtered. The leading `# Title` is dropped: the card's summary already
  # carries the question, and the title would be the largest text on the card.
  def dream_story_html(markdown)
    markdown = markdown.to_s.sub(/\A#\s[^\n]*\n*/, "")
    renderer = Redcarpet::Render::HTML.new(hard_wrap: true, filter_html: true)
    Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, tables: true, autolink: true,
                                      strikethrough: true, no_intra_emphasis: true)
                       .render(markdown).html_safe # rubocop:disable Rails/OutputSafety
  end
end
