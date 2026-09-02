# frozen_string_literal: true

module DeskCapture
  # Pure MIME → structured parts. No S3, no DB — the poll job owns those — so
  # the whole extraction surface is testable against .eml fixtures.
  class Parser
    ENTITY_TAGS = {
      "welding"    => "commercial-welding-llc",
      "cw"         => "commercial-welding-llc",
      "industries" => "mcritchie-industries",
      "studio"     => "mcritchie-studio",
      "turf"       => "turf-monster"
    }.freeze

    Result = Struct.new(:message_id, :from_addr, :subject, :sent_at, :body_text,
                        :entity_hint, :attachments, keyword_init: true)
    Attachment = Struct.new(:filename, :content_type, :body, keyword_init: true)

    def self.parse(raw)
      mail = Mail.read_from_string(raw)

      Result.new(
        message_id: mail.message_id,
        from_addr: mail.from&.first.to_s.downcase,
        subject: mail.subject.to_s,
        sent_at: mail.date&.to_time,
        body_text: extract_body(mail),
        entity_hint: extract_entity_hint(mail),
        attachments: mail.attachments.map { |a|
          Attachment.new(filename: a.filename.to_s, content_type: a.mime_type,
                         body: a.body.decoded)
        }
      )
    end

    # Prefer the plain part; fall back to a crudely de-tagged HTML part. A
    # forwarded transcript usually arrives as plain text either way.
    def self.extract_body(mail)
      if mail.multipart?
        plain = mail.text_part&.decoded
        return plain.to_s.strip if plain.present?

        html = mail.html_part&.decoded
        return html.to_s.gsub(/<[^>]+>/, " ").squeeze(" ").strip if html.present?

        ""
      else
        mail.body.decoded.to_s.strip
      end
    end

    # Subject tag wins ("[welding] site visit notes"), then a plus-address on
    # any recipient (desk+welding@...). A hint is routing ADVICE for the sweep,
    # never trusted blindly.
    def self.extract_entity_hint(mail)
      if (m = mail.subject.to_s.match(/\[([a-z-]+)\]/i))
        tag = m[1].downcase
        return ENTITY_TAGS.fetch(tag, tag)
      end

      recipients = [mail.to, mail.cc, mail["Delivered-To"]&.value].flatten.compact.map(&:to_s)
      recipients.each do |addr|
        if (m = addr.downcase.match(/desk\+([a-z-]+)@/))
          return ENTITY_TAGS.fetch(m[1], m[1])
        end
      end
      nil
    end

    def self.sanitize_filename(name)
      base = name.to_s.strip
      return "attachment" if base.empty?

      base.gsub(/[^A-Za-z0-9._-]+/, "-").squeeze("-")
          .gsub(/-(?=\.)|\A-|-\z/, "").downcase
          .presence || "attachment"
    end
  end
end
