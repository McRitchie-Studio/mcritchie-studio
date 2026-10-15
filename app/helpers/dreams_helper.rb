# frozen_string_literal: true

module DreamsHelper
  # A dream's story body as HTML, through SafeMarkdown (the renderer /docs uses):
  # raw HTML filtered and a javascript: or other unsafe link left as text. The
  # leading `# Title` is dropped: the card's summary already carries the question,
  # and the title would be the largest text on the card.
  def dream_story_html(markdown)
    markdown = markdown.to_s.sub(/\A#\s[^\n]*\n*/, "")
    SafeMarkdown.render(markdown)
  end

  # "N dreams" counted under the page's status filter, as a span that
  # app/javascript/dreams_filter.js recounts when the filter changes. It carries one
  # status token per dream (a blank status reads "none"), so a dream counts once
  # per token and "all" counts every token.
  def dream_count_tag(statuses, filter, **options)
    tokens = statuses.map { |status| status.presence || "none" }
    count = filter.nil? || filter == "all" ? tokens.size : tokens.count(filter)
    data = (options.delete(:data) || {}).merge(dream_count: tokens.join(" "))
    tag.span(pluralize(count, "dream"), data: data, **options)
  end
end
