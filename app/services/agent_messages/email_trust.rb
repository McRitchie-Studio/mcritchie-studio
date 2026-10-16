module AgentMessages
  # Who really sent an email to team@, for the agent mailbox's AUDIENCE
  # decision (docs/agents/system/agent-message-loop.md, "Email"). Pure: raw
  # MIME in, a Verdict out; no database, no network.
  #
  # ONE HEADER IS TRUSTED: the TOPMOST `Authentication-Results`, and only when
  # its authserv-id is `amazonses.com`. Resend's receiver is Amazon SES, the
  # last hop before us, and SES PREPENDS its verdict above everything the sender
  # and the Google group relay wrote. Every lower Authentication-Results, every
  # ARC-Authentication-Results, and anything else a sender can type into its own
  # headers is ignored, because a sender can forge any of them. (DeskCapture::Reader
  # .dkim_from_raw greps every such header; that is fine for a human reading
  # provenance and wrong for this decision.)
  #
  # THE STAMP MUST SIT IN SES'S OWN TRACE BLOCK. Measured on desk item 762
  # (2026-10-16), the raw opens Return-Path, Received (by
  # inbound-smtp.us-east-1.amazonaws.com), X-SES-Spam-Verdict, X-SES-Virus-Verdict,
  # Received-SPF, Authentication-Results: amazonses.com, X-SES-RECEIPT, and only
  # then Google's relay headers. So every header ABOVE the trusted one must be
  # one of those trace headers (TRACE_HEADERS). If SES ever stamped nothing, the
  # topmost Authentication-Results would be a lower one, below the relay's
  # Received/ARC headers, and this check refuses it: a forged
  # `Authentication-Results: amazonses.com … pass` in the sender's own block can
  # never become the trusted one.
  #
  # PASS NEEDS BOTH, ALIGNED WITH THE FROM DOMAIN:
  #   - a `dkim=pass` whose header.d (or header.i's domain) is the From domain or
  #     a parent or child of it (relaxed alignment); SPF is not enough, because
  #     the group hop breaks it, and
  #   - `dmarc=pass` whose header.from is the From domain.
  # One From address only. Anything else is an untrusted verdict: the sender is
  # treated as the public, whoever the From line names.
  class EmailTrust
    TRUSTED_AUTHSERV_ID = "amazonses.com".freeze
    # The headers SES writes above its own verdict (and a Return-Path any MTA writes).
    TRACE_HEADERS = /\A(?:Return-Path|Received|Received-SPF|X-SES-[A-Za-z0-9-]+)\z/i

    Verdict = Struct.new(:verified, :reason, :from_addr, :from_domain, :dkim_domain, keyword_init: true) do
      def verified? = verified == true

      def to_h = { "verified" => verified?, "reason" => reason, "dkim_domain" => dkim_domain }.compact
    end

    # The raw header block as [name, value] pairs, unfolded, in order (topmost first).
    def self.headers(raw)
      head = raw.to_s.b.split(/\r?\n\r?\n/, 2).first.to_s
      head.gsub(/\r?\n[ \t]+/, " ").lines.filter_map do |line|
        name, value = line.chomp.split(":", 2)
        next if value.nil? || name.to_s.strip.empty? || name.match?(/\s/)

        [ name.strip, value.strip.force_encoding(Encoding::UTF_8).scrub ]
      end
    end

    def self.verdict(raw) = new(raw).verdict

    def initialize(raw)
      @headers = self.class.headers(raw)
    end

    def verdict
      from = from_address
      return refuse("the From header must name exactly one address", from) unless from

      domain = from.split("@", 2).last.to_s.downcase
      index = @headers.index { |name, _| name.casecmp?("Authentication-Results") }
      return refuse("no Authentication-Results header", from) unless index

      above = @headers.first(index).map(&:first).reject { |name| name.match?(TRACE_HEADERS) }
      if above.any?
        return refuse("the topmost Authentication-Results sits below #{above.first}, outside the receiver's trace block", from)
      end

      authserv, clauses = parse(@headers[index].last)
      return refuse("the topmost Authentication-Results is from #{authserv.inspect}, not #{TRUSTED_AUTHSERV_ID}", from) unless authserv == TRUSTED_AUTHSERV_ID

      dkim = clauses.select { |c| c[:method] == "dkim" && c[:result] == "pass" }.filter_map { |c| signing_domain(c) }
      aligned = dkim.find { |d| aligned?(d, domain) }
      return refuse("no dkim=pass aligned with #{domain}#{" (passed: #{dkim.join(', ')})" if dkim.any?}", from) unless aligned

      dmarc = clauses.find { |c| c[:method] == "dmarc" }
      return refuse("dmarc=#{dmarc ? dmarc[:result] : 'none'}", from) unless dmarc && dmarc[:result] == "pass"
      unless dmarc[:props]["header.from"].to_s.downcase == domain
        return refuse("dmarc header.from #{dmarc[:props]['header.from'].inspect} is not #{domain}", from)
      end

      Verdict.new(verified: true, reason: "dkim=pass (#{aligned}) and dmarc=pass at #{TRUSTED_AUTHSERV_ID}",
                  from_addr: from, from_domain: domain, dkim_domain: aligned)
    end

    private

    def refuse(reason, from)
      Verdict.new(verified: false, reason: reason, from_addr: from,
                  from_domain: from&.split("@", 2)&.last&.downcase)
    end

    # The one From address, lowercased; nil when there are none, several, or
    # several From headers.
    def from_address
      froms = @headers.select { |name, _| name.casecmp?("From") }
      return nil unless froms.one?

      list = Mail::AddressList.new(froms.first.last).addresses
      return nil unless list.one?

      addr = list.first.address.to_s.strip.downcase
      addr.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) ? addr : nil
    rescue Mail::Field::ParseError, StandardError
      nil
    end

    # "amazonses.com; spf=pass (…) client-ip=…; dkim=pass header.i=@x; dmarc=pass header.from=x"
    # → ["amazonses.com", [{ method:, result:, props: }]]. Comments are dropped first.
    def parse(value)
      text = value.to_s
      2.times { text = text.gsub(/\([^()]*\)/, " ") }
      authserv, *rest = text.split(";").map(&:strip)
      clauses = rest.filter_map do |piece|
        tokens = piece.split(/\s+/)
        head = tokens.shift.to_s
        next unless (m = head.match(/\A(?<method>[a-z0-9_-]+)=(?<result>[a-z0-9_-]+)\z/i))

        props = tokens.filter_map { |t| t.split("=", 2) if t.include?("=") }.to_h { |k, v| [ k.downcase, v.to_s ] }
        { method: m[:method].downcase, result: m[:result].downcase, props: props }
      end
      [ authserv.to_s.split(/\s+/).first.to_s.downcase, clauses ]
    end

    def signing_domain(clause)
      d = clause[:props]["header.d"].presence || clause[:props]["header.i"].to_s.split("@", 2).last.presence
      d&.downcase&.delete_prefix("@")
    end

    # Relaxed alignment: the same domain, or one a subdomain of the other. A
    # signing domain with no dot (a bare TLD) never aligns.
    def aligned?(signing, from_domain)
      return false unless signing.include?(".")

      signing == from_domain || from_domain.end_with?(".#{signing}") || signing.end_with?(".#{from_domain}")
    end
  end
end
