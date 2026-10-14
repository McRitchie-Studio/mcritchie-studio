# frozen_string_literal: true

module DreamsHelper
  # A dream's story body as HTML. Same Redcarpet settings as DocsController, with
  # raw HTML filtered, so a dream renders here exactly as it does under /docs.
  def dream_story_html(markdown)
    renderer = Redcarpet::Render::HTML.new(hard_wrap: true, filter_html: true)
    Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, tables: true, autolink: true,
                                      strikethrough: true, no_intra_emphasis: true)
                       .render(markdown.to_s).html_safe # rubocop:disable Rails/OutputSafety
  end
end
