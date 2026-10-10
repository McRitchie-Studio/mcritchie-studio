# frozen_string_literal: true

# The team@mcritchie.studio capture pipe's object-storage side. Deliberately NOT
# Studio::S3: that facade owns the app's public asset bucket pair
# (mcritchie-studio-{dev,production}, served from a public domain), and raw
# forwarded mail with deal attachments must never land there. The desk bucket
# is its own PRIVATE Cloudflare R2 bucket, `mcritchie-studio-desk` (one bucket,
# no dev/production pair), with its own bucket-scoped keys
# (DESK_CAPTURE_R2_ENDPOINT, DESK_CAPTURE_R2_ACCESS_KEY_ID,
# DESK_CAPTURE_R2_SECRET_ACCESS_KEY; 1Password r2.mcritchie-studio-desk).
#
# R2 is the only backend. The AWS half (an S3 bucket filled by SES inbound, read
# by a poll job) was deleted on 2026-10-10 with the AWS account's keys. Mail
# arrives by the Resend webhook (DeskCaptureResendIngestJob) and the Gmail read
# (Gmail::MailboxIngest). DESK_CAPTURE_BACKEND is optional and accepts only `r2`.
#
# Nothing here is checked at boot: QA and local desks hold no desk keys and never
# ingest. A missing key raises at the first read or write, naming the variable.
module DeskCapture
  PARSED_PREFIX   = "parsed/"
  GMAIL_PREFIX    = "gmail/"

  # Transports whose arrivals skip the sender allowlist.
  #
  # `team@` is a PUBLIC address: anyone can mail it, and the `From:` header they
  # put on it is theirs to choose, so that door checks the sender and
  # quarantines strangers. The Gmail read is not that door — it reads messages
  # already delivered to Mr. McRitchie's own mailbox, selected by a query we
  # control, so the counterparty's address in `From:` is the expected truth
  # rather than a red flag. Quarantining those would drop the body and leave the
  # attachments unextracted, which is the whole payload.
  #
  # The safety hinges on `source` being unforgeable: it is an argument our own
  # callers pass, never a header. DeskCaptureResendIngestJob does not pass it and
  # so cannot become trusted, which is the property `ingest_raw` is tested for.
  TRUSTED_SOURCES = %w[gmail].freeze

  class << self
    def bucket
      ENV.fetch("DESK_CAPTURE_BUCKET", "mcritchie-studio-desk")
    end

    # Raises on any DESK_CAPTURE_BACKEND but `r2` (or unset): the S3 backend is
    # gone, so an old value must fail loudly rather than read as a selection.
    def backend!
      value = ENV["DESK_CAPTURE_BACKEND"].to_s.strip
      return "r2" if value.empty? || value.casecmp?("r2")

      raise ArgumentError, "DESK_CAPTURE_BACKEND=#{value.inspect} is not supported: DeskCapture runs on " \
                           "Cloudflare R2 only (the S3 backend was retired 2026-10-10). Unset it or set r2."
    end

    def client
      @client ||= begin
        require "aws-sdk-s3"
        Aws::S3::Client.new(**client_options)
      end
    end

    def client_options
      backend!
      { region: "auto",
        endpoint: ENV.fetch("DESK_CAPTURE_R2_ENDPOINT"),
        access_key_id: ENV.fetch("DESK_CAPTURE_R2_ACCESS_KEY_ID"),
        secret_access_key: ENV.fetch("DESK_CAPTURE_R2_SECRET_ACCESS_KEY") }
    end

    def reset!
      @client = nil
    end

    def trusted_source?(source)
      TRUSTED_SOURCES.include?(source.to_s)
    end

    def read(key)
      client.get_object(bucket: bucket, key: key).body.read
    end

    def store(key, body, content_type: nil)
      opts = { bucket: bucket, key: key, body: body }
      opts[:content_type] = content_type if content_type
      client.put_object(**opts)
      key
    end

    # Shared ingestion core — raw MIME + a durable key in, one DeskCaptureItem
    # out. Both transports (the Resend webhook and the Gmail read) run through
    # here. Idempotent on s3_key.
    #
    # `source` is the TRANSPORT, chosen by the calling code and never read off
    # the message. Everything about trust hangs on that: see TRUSTED_SOURCES.
    def ingest_raw(raw:, s3_key:, source: "resend", history_id: nil)
      return DeskCaptureItem.find_by(s3_key: s3_key) if DeskCaptureItem.exists?(s3_key: s3_key)

      parsed = Parser.parse(raw)
      trusted = trusted_source?(source) || DeskCaptureItem.allowlisted?(parsed.from_addr)

      item = DeskCaptureItem.new(
        s3_key: s3_key,
        source: source,
        history_id: history_id,
        message_id: parsed.message_id,
        from_addr: parsed.from_addr,
        subject: parsed.subject,
        received_at: parsed.sent_at || Time.current,
        entity_hint: parsed.entity_hint,
        status: trusted ? "received" : "quarantined",
        body_text: trusted ? parsed.body_text : nil,
        attachments: []
      )

      # Attachments extract for TRUSTED mail only — quarantined raw stays
      # sealed where nothing renders or executes it.
      if trusted
        base = s3_key.sub(%r{\A[^/]+/}, "").sub(/\.eml\z/, "")
        item.attachments = parsed.attachments.each_with_index.map do |att, idx|
          stored = store("#{PARSED_PREFIX}#{base}/#{idx}-#{Parser.sanitize_filename(att.filename)}",
                         att.body, content_type: att.content_type)
          { "filename" => att.filename, "s3_key" => stored,
            "content_type" => att.content_type, "byte_size" => att.body.to_s.bytesize }
        end
      end

      item.save!
      item
    end
  end

  # The Resend API surface the inbound leg needs — two calls, both stubbed in
  # tests. Auth rides the hub's existing RESEND_API_KEY.
  module ResendClient
    BASE = "https://api.resend.com"

    class << self
      def fetch_received(id)
        require "net/http"
        uri = URI("#{BASE}/emails/receiving/#{id}")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{ENV.fetch('RESEND_API_KEY')}"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
        raise "Resend retrieve #{id} failed: #{res.code}" unless res.code.to_i == 200

        JSON.parse(res.body)
      end

      # The most recent received emails, newest first — the ledger the desk
      # health check compares against DeskCaptureItem. Returns the `data` rows.
      def list_received(limit: 50)
        require "net/http"
        uri = URI("#{BASE}/emails/receiving?limit=#{Integer(limit)}")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{ENV.fetch('RESEND_API_KEY')}"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
          http.request(req)
        end
        raise "Resend list received failed: #{res.code}" unless res.code.to_i == 200

        Array(JSON.parse(res.body)["data"])
      end

      def fetch_url(url)
        require "net/http"
        res = Net::HTTP.get_response(URI(url))
        raise "Resend raw download failed: #{res.code}" unless res.code.to_i == 200

        res.body
      end
    end
  end
end
