# frozen_string_literal: true

module DeskCapture
  # What `bin/mail desk` reads: the queue as rows, or one item with its body and,
  # on request, its raw .eml and every attachment as bytes.
  #
  # QUARANTINE IS SEALED HERE TOO. A quarantined item came from a sender off the
  # allowlist; the knowledge-capture SOP reports it and never processes it. So
  # its payload carries no body and no files, only the dkim verdict from its raw
  # headers (so the operator can judge provenance) and the instruction to report.
  class Reader
    LIST_LIMIT = 200
    ZONE = "America/Denver"
    REPORT = "QUARANTINED — sender is not on the desk allowlist. Report it to the operator; do not process it."

    def initialize(store: DeskCapture)
      @store = store
    end

    def list(since:)
      DeskCaptureItem.where(received_at: since..).recent_first.limit(LIST_LIMIT).map do |item|
        {
          "id" => item.id,
          "received_at" => denver(item.received_at),
          "source" => item.source,
          "status" => item.status,
          "from" => item.from_addr,
          "subject" => item.subject,
          "attachments" => attachment_rows(item).map { |a| a["filename"] }
        }
      end
    end

    def item(id, files: false)
      item = DeskCaptureItem.find_by(id: id) or raise ArgumentError, "no desk item #{id}"
      payload = {
        "id" => item.id,
        "received_at" => denver(item.received_at),
        "source" => item.source,
        "status" => item.status,
        "from" => item.from_addr,
        "subject" => item.subject,
        "entity_hint" => item.entity_hint,
        "attachments" => attachment_rows(item).map { |a| a["filename"] },
        "quarantined" => item.quarantined?
      }
      return payload.merge("notice" => REPORT, "dkim" => dkim_line(item), "files" => []) if item.quarantined?

      payload.merge("body" => item.body_text.to_s, "files" => files ? files_for(item) : [])
    end

    # The dkim clause(s) of the raw's Authentication-Results header(s), unfolded.
    # Headers only: the body of a quarantined message is never read into output.
    def self.dkim_from_raw(raw)
      head = raw.to_s.split(/\r?\n\r?\n/, 2).first.to_s.gsub(/\r?\n[ \t]+/, " ")
      results = head.lines.grep(/\AAuthentication-Results:/i)
      clauses = results.flat_map do |line|
        line.sub(/\AAuthentication-Results:\s*/i, "").split(";").map(&:strip).grep(/\Adkim=/i)
      end
      clauses.empty? ? nil : clauses.join("; ")
    end

    private

    def dkim_line(item)
      found = self.class.dkim_from_raw(@store.read(item.s3_key))
      "Authentication-Results dkim: #{found || '(none in the raw headers)'}"
    rescue StandardError => e
      "Authentication-Results dkim: (raw unreadable — #{e.class})"
    end

    def files_for(item)
      files = [ file("item-#{item.id}.eml", @store.read(item.s3_key)) ]
      attachment_rows(item).each_with_index do |att, idx|
        files << file("#{idx}-#{Parser.sanitize_filename(att['filename'])}", @store.read(att["s3_key"]))
      end
      files
    end

    def file(name, bytes) = { "name" => name, "base64" => Base64.strict_encode64(bytes.to_s) }

    def attachment_rows(item) = item.attachments.is_a?(Array) ? item.attachments : []

    def denver(time) = time&.in_time_zone(ZONE)&.strftime("%Y-%m-%d %H:%M %Z")
  end
end
