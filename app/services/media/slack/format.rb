module Media
  class Slack < Adapter
    # Discord-shaped content into Slack's: Markdown into mrkdwn, and a Discord
    # embed list (release notes, reports, app requests) into minimal Block Kit.
    # Pure. Limits are Slack's: a section's text at most 3000 characters, at
    # most 50 blocks a message, a section at most 10 fields of 2000.
    module Format
      SECTION_LIMIT = 3000
      FIELD_LIMIT = 2000
      FIELDS_PER_SECTION = 10
      BLOCKS_PER_MESSAGE = 50
      # The fallback `text` (notifications, screen readers) is clipped well under
      # Slack's 40,000-character truncation.
      TEXT_LIMIT = 3900

      module_function

      # Markdown to Slack mrkdwn: & < > escaped first, then **bold** → *bold*,
      # __x__ → _x_, ~~x~~ → ~x~, [text](url) → <url|text>, and a "# Heading"
      # line → *Heading*. Code spans and blocks pass through unchanged in shape.
      def mrkdwn(text)
        out = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
        out = out.gsub(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/) { "<#{Regexp.last_match(2)}|#{Regexp.last_match(1).tr('|', '¦')}>" }
        out = out.gsub(/\*\*(.+?)\*\*/m, '*\1*')
        out = out.gsub(/(?<![\w_])__(.+?)__(?![\w_])/m, '_\1_')
        out = out.gsub(/~~(.+?)~~/m, '~\1~')
        out.gsub(/^\#{1,6}\s+(.+)$/) { "*#{Regexp.last_match(1).strip.delete('*')}*" }
      end

      # The messages one post makes: [{ text:, blocks: }…]. Plain content alone
      # is one message with no blocks (Slack renders `text` as mrkdwn); embeds
      # become a section per embed under the content, split into messages of at
      # most BLOCKS_PER_MESSAGE blocks.
      def messages(content: nil, embeds: nil)
        content = content.to_s
        embeds = Array(embeds).map { |e| e.to_h.deep_stringify_keys }
        if embeds.empty?
          return [] if content.strip.empty?

          return chunks(mrkdwn(content), TEXT_LIMIT).map { |chunk| { text: chunk } }
        end

        blocks = chunks(mrkdwn(content), SECTION_LIMIT).map { |chunk| section(chunk) }
        embeds.each do |embed|
          blocks << { type: "divider" } if blocks.any?
          blocks.concat(embed_blocks(embed))
        end
        blocks.each_slice(BLOCKS_PER_MESSAGE).with_index.map do |slice, i|
          { text: clip(fallback_text(content, embeds, i), TEXT_LIMIT), blocks: slice }
        end
      end

      def embed_blocks(embed)
        title = embed["title"].to_s.strip
        title = embed["url"].present? ? "*<#{embed['url']}|#{escape(title).tr('|', '¦')}>*" : "*#{escape(title)}*" if title.present?
        head = [ title.presence, mrkdwn(embed["description"]).presence ].compact.join("\n")
        blocks = chunks(head, SECTION_LIMIT).map { |chunk| section(chunk) }
        fields = Array(embed["fields"]).filter_map do |field|
          field = field.to_h.stringify_keys
          line = [ "*#{escape(field['name'])}*", mrkdwn(field["value"]) ].reject { |part| part.strip.empty? || part == "**" }.join("\n")
          line.presence && { type: "mrkdwn", text: clip(line, FIELD_LIMIT) }
        end
        fields.each_slice(FIELDS_PER_SECTION) { |slice| blocks << { type: "section", fields: slice } }
        footer = embed.dig("footer", "text").to_s.strip
        blocks << { type: "context", elements: [ { type: "mrkdwn", text: clip(mrkdwn(footer), FIELD_LIMIT) } ] } if footer.present?
        blocks
      end

      def section(text) = { type: "section", text: { type: "mrkdwn", text: text } }

      def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

      def fallback_text(content, embeds, index)
        lead = content.strip.presence || embeds.filter_map { |e| e["title"].presence }.first.to_s
        index.zero? ? mrkdwn(lead) : "#{mrkdwn(lead)} (continued)"
      end

      def clip(text, limit) = text.length > limit ? "#{text[0, limit - 1]}…" : text

      # Splits on line boundaries into pieces of at most `limit`; a line longer
      # than the limit is hard-cut.
      def chunks(text, limit)
        return [] if text.to_s.strip.empty?

        pieces = []
        current = +""
        text.split("\n", -1).flat_map { |line| line.length > limit ? line.scan(/.{1,#{limit}}/m) : [ line ] }.each do |line|
          if current.empty?
            current = line.dup
          elsif current.length + 1 + line.length <= limit
            current << "\n" << line
          else
            pieces << current
            current = line.dup
          end
        end
        pieces << current unless current.strip.empty?
        pieces
      end
    end
  end
end
