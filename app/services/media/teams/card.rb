module Media
  class Teams < Adapter
    # What the agents post on Teams: an Adaptive Card per message, headed with
    # the soul's name and portrait (one bot posts as every soul and Teams lets a
    # bot set no per-message display name). Pure.
    #
    # Built to learn.microsoft.com, checked 2026-10-30
    # (task-modules-and-cards/cards/cards-reference): bot-sent cards support
    # Adaptive Card schema 1.6 or earlier, on mobile too; VERSION is 1.5, the
    # lowest that carries everything used here, for older clients. A card image
    # is an HTTPS URL to a PNG/JPEG/GIF of at most 1024x1024 (the portraits
    # under public/slack-icons/ are). A message is at most ~100 KB counted as
    # UTF-16, 80 KB to be safe (bots/how-to/format-your-bot-messages), so a
    # TextBlock carries at most TEXT_LIMIT characters and a longer post is
    # chunked into several cards. A reply is ONE card, clipped, so a retry can
    # never leave half an answer posted twice.
    module Card
      CONTENT_TYPE = "application/vnd.microsoft.card.adaptive".freeze
      SCHEMA = "http://adaptivecards.io/schemas/adaptive-card.json".freeze
      VERSION = "1.5".freeze
      # 20,000 characters is at most 40 KB of UTF-16, half the safe size, which
      # leaves room for the header and the JSON around it.
      TEXT_LIMIT = 20_000
      FACT_LIMIT = 2_000

      module_function

      # A message activity carrying one card: the header, `text` (Markdown,
      # which a TextBlock renders a subset of: bold, italic, lists, links), and
      # any further body elements.
      def activity(text:, name:, icon_url: nil, body: [])
        blocks = []
        blocks << header(name, icon_url) if name.present?
        blocks << text_block(clip(text.to_s, TEXT_LIMIT)) if text.to_s.strip.present?
        blocks.concat(body)
        {
          type: "message",
          attachments: [ { contentType: CONTENT_TYPE,
                           content: { "$schema": SCHEMA, type: "AdaptiveCard", version: VERSION, body: blocks,
                                      msteams: { width: "Full" } } } ]
        }
      end

      # The header: the portrait (a person-style image) beside the soul's name.
      def header(name, icon_url)
        columns = []
        if icon_url.present?
          columns << { type: "Column", width: "auto",
                       items: [ { type: "Image", url: icon_url, size: "Small", style: "Person", altText: name } ] }
        end
        columns << { type: "Column", width: "stretch", verticalContentAlignment: "Center",
                     items: [ { type: "TextBlock", text: name, weight: "Bolder", wrap: true } ] }
        { type: "ColumnSet", columns: columns }
      end

      def text_block(text, **opts) = { type: "TextBlock", text: text, wrap: true }.merge(opts)

      # The activities one post makes. Content alone is chunked on line
      # boundaries into cards of at most TEXT_LIMIT; Discord-shaped embeds
      # become body elements under the last chunk (a title, its description, a
      # FactSet of its fields, a subtle footer).
      def messages(content: nil, embeds: nil, name: nil, icon_url: nil)
        chunks = Media::Slack::Format.chunks(content.to_s, TEXT_LIMIT)
        extra = Array(embeds).flat_map { |embed| embed_body(embed.to_h.deep_stringify_keys) }
        return [] if chunks.empty? && extra.empty?

        chunks = [ "" ] if chunks.empty?
        chunks.each_with_index.map do |chunk, i|
          activity(text: chunk, name: (name if i.zero?), icon_url: icon_url, body: i == chunks.length - 1 ? extra : [])
        end
      end

      def embed_body(embed)
        body = []
        title = embed["title"].to_s.strip
        if title.present?
          title = "[#{title.tr('[]', '()')}](#{embed['url']})" if embed["url"].to_s.start_with?("https://")
          body << text_block(clip(title, FACT_LIMIT), weight: "Bolder", size: "Medium", separator: true)
        end
        body << text_block(clip(embed["description"].to_s, TEXT_LIMIT)) if embed["description"].to_s.strip.present?
        facts = Array(embed["fields"]).filter_map do |field|
          field = field.to_h.stringify_keys
          next if field["name"].to_s.strip.empty? && field["value"].to_s.strip.empty?

          { title: clip(field["name"].to_s, FACT_LIMIT), value: clip(field["value"].to_s, FACT_LIMIT) }
        end
        body << { type: "FactSet", facts: facts } if facts.any?
        footer = embed.dig("footer", "text").to_s.strip
        body << text_block(clip(footer, FACT_LIMIT), isSubtle: true, size: "Small") if footer.present?
        body
      end

      def clip(text, limit) = Media::Slack::Format.clip(text, limit)
    end
  end
end
