# Polls the private desk bucket for SES drops and turns each new object into a
# DeskCaptureItem. Idempotent on s3_key — a re-poll of the same object creates
# nothing. Runs every 5 minutes via config/recurring.yml.
#
# Failure posture: NO silent rescues (the QA-shared-bucket scar). A missing
# credential in dev skips politely via DeskCapture.configured?; anything else
# raises and lands in ErrorLog where it belongs.
class DeskCapturePollJob < ApplicationJob
  queue_as :default

  def perform
    return unless DeskCapture.configured?

    DeskCapture.list_incoming_keys.each do |key|
      next if DeskCaptureItem.exists?(s3_key: key)

      ingest(key)
    end
  end

  private

  def ingest(key)
    raw = DeskCapture.read(key)
    parsed = DeskCapture::Parser.parse(raw)
    allowlisted = DeskCaptureItem.allowlisted?(parsed.from_addr)

    item = DeskCaptureItem.new(
      s3_key: key,
      message_id: parsed.message_id,
      from_addr: parsed.from_addr,
      subject: parsed.subject,
      received_at: parsed.sent_at || Time.current,
      entity_hint: parsed.entity_hint,
      status: allowlisted ? "received" : "quarantined",
      body_text: allowlisted ? parsed.body_text : nil,
      attachments: []
    )

    # Attachments are extracted for ALLOWLISTED mail only — quarantined raw
    # stays sealed in incoming/ where nothing renders or executes it.
    if allowlisted
      base = key.delete_prefix(DeskCapture::INCOMING_PREFIX)
      item.attachments = parsed.attachments.each_with_index.map do |att, idx|
        stored = DeskCapture.store(
          "#{DeskCapture::PARSED_PREFIX}#{base}/#{idx}-#{DeskCapture::Parser.sanitize_filename(att.filename)}",
          att.body, content_type: att.content_type
        )
        { "filename" => att.filename, "s3_key" => stored,
          "content_type" => att.content_type, "byte_size" => att.body.to_s.bytesize }
      end
    end

    item.save!
  end
end
