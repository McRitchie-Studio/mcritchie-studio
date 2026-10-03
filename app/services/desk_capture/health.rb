# frozen_string_literal: true

require "resolv"

module DeskCapture
  # Is mail to team@ actually reaching the desk? Two checks, both read-only.
  #
  # 1. MX. `in.mcritchie.studio` must route to SES inbound. From 2026-09-29 to
  #    2026-10-02 that record was simply gone from the zone, nothing arrived, and
  #    nothing said so. Resend's domain API kept reporting every record
  #    "verified" throughout, so it is NOT a health signal; only a live DNS
  #    answer is.
  # 2. Ingest. Every email Resend says it received (older than GRACE, so an
  #    in-flight webhook is not a false alarm) must have a DeskCaptureItem at
  #    `resend/<id>.eml`. A missing one is a dropped ingest.
  #
  # The resolver and the Resend client are injected so the unit tests run with
  # no network at all.
  class Health
    MX_HOST = "in.mcritchie.studio"
    EXPECTED_MX = "inbound-smtp.us-east-1.amazonaws.com"
    GRACE = 10.minutes
    RESEND_LIMIT = 50

    HealthError = Class.new(StandardError)

    Result = Struct.new(:failures, :notes, keyword_init: true) do
      def ok? = failures.empty?

      def message
        lines = failures.map { |f| "FAIL #{f}" } + notes.map { |n| "ok   #{n}" }
        lines.join("\n")
      end
    end

    def initialize(resolver: nil, resend: ResendClient, now: -> { Time.current }, limit: RESEND_LIMIT)
      @resolver = resolver
      @resend = resend
      @now = now
      @limit = limit
    end

    def check
      failures = []
      notes = []
      check_mx(failures, notes)
      check_ingest(failures, notes)
      Result.new(failures: failures, notes: notes)
    end

    private

    def check_mx(failures, notes)
      exchanges = mx_exchanges
      if exchanges.include?(EXPECTED_MX)
        notes << "MX #{MX_HOST} -> #{EXPECTED_MX}"
      else
        found = exchanges.empty? ? "no MX record" : exchanges.join(", ")
        failures << "MX #{MX_HOST} does not route to #{EXPECTED_MX} (found: #{found}). " \
                    "Inbound mail to team@ is NOT arriving — restore the record in the Cloudflare zone."
      end
    rescue StandardError => e
      failures << "MX lookup for #{MX_HOST} failed: #{e.class}: #{e.message}"
    end

    def mx_exchanges
      if @resolver
        return @resolver.getresources(MX_HOST, Resolv::DNS::Resource::IN::MX).map { |r| normalize(r.exchange) }
      end

      Resolv::DNS.open do |dns|
        dns.timeouts = 5
        dns.getresources(MX_HOST, Resolv::DNS::Resource::IN::MX).map { |r| normalize(r.exchange) }
      end
    end

    def normalize(name) = name.to_s.downcase.chomp(".")

    def check_ingest(failures, notes)
      rows = @resend.list_received(limit: @limit)
      cutoff = @now.call - GRACE
      # An unreadable timestamp counts as settled: fail toward a visible alarm.
      settled = rows.select { |row| (at = parse_time(row["created_at"])).nil? || at <= cutoff }
      keys = settled.to_h { |row| [ "resend/#{row['id']}.eml", row ] }
      present = DeskCaptureItem.where(s3_key: keys.keys).pluck(:s3_key)
      missing = keys.keys - present

      if missing.empty?
        notes << "ingest: #{settled.size} settled Resend email(s), all on the desk"
      else
        ids = missing.map { |k| k.delete_prefix("resend/").delete_suffix(".eml") }
        failures << "ingest dropped #{missing.size} Resend email(s) with no DeskCaptureItem: #{ids.join(', ')}. " \
                    "Re-run DeskCaptureResendIngestJob.perform_now(<id>) for each."
      end
    rescue StandardError => e
      failures << "could not list Resend received emails: #{e.class}: #{e.message}"
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
