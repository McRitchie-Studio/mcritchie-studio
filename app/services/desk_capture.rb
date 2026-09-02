# frozen_string_literal: true

# The desk@mcritchie.studio capture pipe's S3 side. Deliberately NOT
# Studio::S3: that facade owns the app's public asset bucket pair
# (mcritchie-studio-{dev,production}, world-readable by policy), and raw
# forwarded mail with deal attachments must never land there. The desk bucket
# is its own PRIVATE bucket in us-east-1 (SES inbound's region), reachable with
# the app's existing AWS credentials.
module DeskCapture
  INCOMING_PREFIX = "incoming/"
  PARSED_PREFIX   = "parsed/"

  class << self
    def bucket
      ENV.fetch("DESK_CAPTURE_BUCKET", "mcritchie-studio-desk")
    end

    def region
      ENV.fetch("DESK_CAPTURE_REGION", "us-east-1")
    end

    # Whether this environment can touch the capture bucket at all. Local desks
    # without AWS credentials skip polling rather than erroring every 5 minutes;
    # production misconfiguration still fails loudly inside the job.
    def configured?
      ENV["AWS_ACCESS_KEY_ID"].present?
    end

    def client
      @client ||= begin
        require "aws-sdk-s3"
        Aws::S3::Client.new(region: region)
      end
    end

    def reset!
      @client = nil
    end

    def list_incoming_keys(max: 200)
      client.list_objects_v2(bucket: bucket, prefix: INCOMING_PREFIX, max_keys: max)
            .contents.map(&:key)
            .reject { |k| k.end_with?("/") || k.end_with?("AMAZON_SES_SETUP_NOTIFICATION") }
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
    # out. Both transports converge here: the Resend webhook leg (primary) and
    # the SES poller (kept as a manual fallback). Idempotent on s3_key.
    def ingest_raw(raw:, s3_key:)
      return DeskCaptureItem.find_by(s3_key: s3_key) if DeskCaptureItem.exists?(s3_key: s3_key)

      parsed = Parser.parse(raw)
      allowlisted = DeskCaptureItem.allowlisted?(parsed.from_addr)

      item = DeskCaptureItem.new(
        s3_key: s3_key,
        message_id: parsed.message_id,
        from_addr: parsed.from_addr,
        subject: parsed.subject,
        received_at: parsed.sent_at || Time.current,
        entity_hint: parsed.entity_hint,
        status: allowlisted ? "received" : "quarantined",
        body_text: allowlisted ? parsed.body_text : nil,
        attachments: []
      )

      # Attachments extract for ALLOWLISTED mail only — quarantined raw stays
      # sealed where nothing renders or executes it.
      if allowlisted
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

      def fetch_url(url)
        require "net/http"
        res = Net::HTTP.get_response(URI(url))
        raise "Resend raw download failed: #{res.code}" unless res.code.to_i == 200

        res.body
      end
    end
  end
end
