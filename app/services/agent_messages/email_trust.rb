module AgentMessages
  # Who really sent an email to team@, for the agent mailbox's AUDIENCE
  # decision (docs/agents/system/agent-message-loop.md, "Email"). Pure: raw
  # MIME in, a Verdict out; no database, no network.
  #
  # ONE HEADER IS TRUSTED: SES's own `Authentication-Results: amazonses.com`.
  # Resend's receiver is Amazon SES, the last hop before us. Every other
  # Authentication-Results, every ARC-Authentication-Results, and anything else a
  # sender can type into its own headers is ignored. (DeskCapture::Reader
  # .dkim_from_raw greps every such header; that is fine for a human reading
  # provenance and wrong for this decision.)
  #
  # WHERE IT MUST SIT. Measured on desk item 762 (2026-10-16), SES writes, in
  # order: Return-Path, Received (by inbound-smtp…amazonaws.com), X-SES-Spam-Verdict,
  # X-SES-Virus-Verdict, Received-SPF, Authentication-Results: amazonses.com, then
  # X-SES-RECEIPT, and only below that anything the relay or the sender wrote.
  # The trusted header is the TOPMOST Authentication-Results, every header above
  # it is one of those trace headers (TRACE_HEADERS), and it sits ABOVE the first
  # X-SES-RECEIPT. With no X-SES-RECEIPT the sender is untrusted. This proves
  # nothing on its own if SES ever wrote neither its verdict nor its receipt: a
  # sender mailing SES directly could then lay out a whole fake trace block. It
  # does refuse every forgery that sits below SES's receipt, which is wherever a
  # sender's own lines land while SES stamps its receipt.
  #
  # HOW IT IS READ (hardened 2026-10-16 after Carl's review: SES copies the SMTP
  # envelope-from and HELO into this header, so a sender controls text inside it):
  #   - quoted strings and comments are removed first (an envelope-from of
  #     `"x;dkim=pass …"@evil.example` leaves nothing behind);
  #   - SES folds one RESULT per line. Only a method=result that STARTS a folded
  #     line is a result; a method=result anywhere else (a HELO of
  #     `x;dkim=pass<TAB>header.d=…`) refuses the whole header;
  #   - exactly one dmarc result, and it is the last result;
  #   - dkim is read only from the run of dkim results just before it.
  #
  # PASS NEEDS BOTH, ALIGNED WITH THE FROM DOMAIN:
  #   - a `dkim=pass` whose header.d (or header.i's domain) is the From domain or
  #     a parent or child of it (relaxed alignment); SPF is not enough, because
  #     the group hop breaks it, and
  #   - `dmarc=pass` whose header.from is the From domain.
  # One From address only.
  #
  # PINNED SELECTORS. The domain check proves the DOMAIN, not the mailbox: any
  # holder of RESEND_API_KEY can send DKIM-passing mail `From: alex@mcritchie.studio`
  # under the `resend` selector. For a domain listed in `pinned` (config/agent_routes.yml
  # `email.pinned_dkim`: mcritchie.studio → [google], Alex's Google Workspace
  # key), every DKIM-Signature aligned with the From domain must name a pinned
  # selector (`s=`), and at least one must. SES's verdict does not print the
  # selector, so it is read from the DKIM-Signature headers: if every aligned
  # signature uses a pinned selector, the aligned pass SES reports can only be a
  # pinned one. A forged extra s=google signature cannot hide a real s=resend one,
  # because the resend one is still there and refuses the mail.
  #
  # Anything else is an untrusted verdict: the sender is treated as the public,
  # whoever the From line names.
  class EmailTrust
    TRUSTED_AUTHSERV_ID = "amazonses.com".freeze
    RECEIPT_HEADER = "X-SES-RECEIPT".freeze
    # The headers SES writes above its own verdict (and a Return-Path any MTA writes).
    TRACE_HEADERS = /\A(?:Return-Path|Received|Received-SPF|X-SES-[A-Za-z0-9-]+)\z/i
    METHOD_RESULT = /\A(?<method>[a-z0-9_-]+)\s*=\s*(?<result>[a-z0-9_-]+)\z/i
    # A result keyword at a token start anywhere in the header: counted, so one
    # smuggled into a property value cannot pass unseen.
    KNOWN_METHODS = %w[spf dkim dmarc arc iprev auth dkim-atps bimi].freeze
    RESULT_TOKEN = /(?:\A|[\s;])(?<method>#{KNOWN_METHODS.map { |m| Regexp.escape(m) }.join('|')})\s*=/i

    Verdict = Struct.new(:verified, :reason, :from_addr, :from_domain, :dkim_domain, keyword_init: true) do
      def verified? = verified == true

      def to_h = { "verified" => verified?, "reason" => reason, "dkim_domain" => dkim_domain }.compact
    end

    # The raw header block as [name, unfolded value, folded value] triples, in
    # order (topmost first). A name with space before its colon ("From :") is
    # still that header.
    def self.fields(raw)
      head = raw.to_s.b.split(/\r?\n\r?\n/, 2).first.to_s
      head.split(/\r?\n(?![ \t])/).filter_map do |field|
        name, value = field.split(":", 2)
        name = name.to_s.strip
        next if value.nil? || name.empty? || name.match?(/\s/)

        folded = value.force_encoding(Encoding::UTF_8).scrub
        [ name, folded.gsub(/\r?\n[ \t]+/, " ").strip, folded ]
      end
    end

    # [name, value] pairs, unfolded (EmailLoopGuard reads these).
    def self.headers(raw) = fields(raw).map { |name, value, _| [ name, value ] }

    def self.verdict(raw, pinned: nil) = new(raw, pinned: pinned).verdict

    # pinned: { "mcritchie.studio" => ["google"] }; default from config/agent_routes.yml.
    def initialize(raw, pinned: nil)
      @fields = self.class.fields(raw)
      @pinned = (pinned || EmailRoutes.current.pinned_dkim).to_h { |d, s| [ d.to_s.downcase, Array(s).map { |x| x.to_s.downcase } ] }
    end

    def verdict
      from = from_address
      return refuse("the From header must name exactly one address", from) unless from

      domain = from.split("@", 2).last.to_s.downcase
      index = @fields.index { |name, _, _| name.casecmp?("Authentication-Results") }
      return refuse("no Authentication-Results header", from) unless index

      receipt = @fields.index { |name, _, _| name.casecmp?(RECEIPT_HEADER) }
      return refuse("no #{RECEIPT_HEADER} header: not stamped by SES", from) unless receipt
      return refuse("the topmost Authentication-Results sits below SES's #{RECEIPT_HEADER}", from) unless index < receipt

      above = @fields.first(index).map(&:first).reject { |name| name.match?(TRACE_HEADERS) }
      if above.any?
        return refuse("the topmost Authentication-Results sits below #{above.first}, outside the receiver's trace block", from)
      end

      authserv, results, why = parse(@fields[index].last)
      return refuse(why, from) if why
      return refuse("the topmost Authentication-Results is from #{authserv.inspect}, not #{TRUSTED_AUTHSERV_ID}", from) unless authserv == TRUSTED_AUTHSERV_ID

      dmarcs = results.select { |r| r[:method] == "dmarc" }
      return refuse("#{dmarcs.size} dmarc results; exactly one is trusted", from) unless dmarcs.one?
      return refuse("the dmarc result is not the last result", from) unless results.last[:method] == "dmarc"

      dmarc = dmarcs.first
      dkim_run = results[0...-1].reverse.take_while { |r| r[:method] == "dkim" }
      dkim = dkim_run.select { |r| r[:result] == "pass" }.filter_map { |r| signing_domain(r) }
      aligned = dkim.find { |d| aligned?(d, domain) }
      return refuse("no dkim=pass aligned with #{domain}#{" (passed: #{dkim.join(', ')})" if dkim.any?}", from) unless aligned
      return refuse("dmarc=#{dmarc[:result]}", from) unless dmarc[:result] == "pass"
      unless dmarc[:props]["header.from"].to_s.downcase == domain
        return refuse("dmarc header.from #{dmarc[:props]['header.from'].inspect} is not #{domain}", from)
      end
      if (why = selector_refusal(domain))
        return refuse(why, from)
      end

      Verdict.new(verified: true, reason: "dkim=pass (#{aligned}) and dmarc=pass at #{TRUSTED_AUTHSERV_ID}",
                  from_addr: from, from_domain: domain, dkim_domain: aligned)
    end

    # Removes quoted strings (with their backslash pairs) and comments (nested,
    # with quoted pairs), keeping line breaks so the folded layout survives.
    def self.sanitize(text)
      out = +""
      depth = 0
      quoted = false
      chars = text.to_s.chars
      i = 0
      while i < chars.size
        c = chars[i]
        if c == "\\" && (quoted || depth.positive?)
          i += 2
          next
        end
        if quoted || depth.positive?
          out << c if c == "\n" # keep the folded layout
          if quoted
            quoted = false if c == '"'
          else
            depth += 1 if c == "("
            depth -= 1 if c == ")"
          end
        elsif c == '"'
          quoted = true
        elsif c == "("
          depth += 1
        else
          out << c
        end
        i += 1
      end
      out
    end

    private

    def refuse(reason, from)
      Verdict.new(verified: false, reason: reason, from_addr: from,
                  from_domain: from&.split("@", 2)&.last&.downcase)
    end

    # The one From address, lowercased; nil when there are none, several, or
    # several From headers.
    def from_address
      froms = @fields.select { |name, _, _| name.casecmp?("From") }
      return nil unless froms.one?

      list = Mail::AddressList.new(froms.first[1]).addresses
      return nil unless list.one?

      addr = list.first.address.to_s.strip.downcase
      addr.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) ? addr : nil
    rescue Mail::Field::ParseError, StandardError
      nil
    end

    # The folded value → [authserv-id, results, refusal or nil]. Line 1 holds the
    # authserv-id; each later folded line is ONE result: `method=result` first,
    # then its properties (`;`-separated pieces on that line, SES's spf line
    # carries client-ip, envelope-from and helo that way).
    def parse(folded)
      clean = self.class.sanitize(folded)
      lines = clean.split(/\r?\n/).map(&:strip).reject(&:empty?)
      first, *rest = lines
      authserv_part, *inline = first.to_s.split(";").map(&:strip)
      authserv = authserv_part.to_s.split(/\s+/).first.to_s.downcase
      return [ authserv, [], "results written on the authserv-id line" ] if inline.reject(&:empty?).any?

      results = rest.map do |line|
        head, *props = line.split(";").map(&:strip)
        tokens = head.to_s.split(/\s+/)
        m = tokens.shift.to_s.match(METHOD_RESULT)
        return [ authserv, [], "a folded line does not start with method=result" ] unless m

        pairs = (tokens + props.flat_map { |p| p.split(/\s+/) }).filter_map { |t| t.split("=", 2) if t.include?("=") }
        { method: m[:method].downcase, result: m[:result].downcase,
          props: pairs.to_h { |k, v| [ k.downcase, v.to_s.delete_suffix(";") ] } }
      end
      return [ authserv, [], "no results" ] if results.empty?

      # Every result keyword in the header must be one of the line-start results.
      tokens = clean.to_enum(:scan, RESULT_TOKEN).map { Regexp.last_match[:method].downcase }
      starts = results.map { |r| r[:method] }.select { |m| KNOWN_METHODS.include?(m) }
      return [ authserv, [], "a result appears inside another result's properties" ] unless tokens.sort == starts.sort

      [ authserv, results, nil ]
    end

    # nil when the From domain is not pinned, or every DKIM-Signature aligned with
    # it names a pinned selector (and one does); else why not.
    def selector_refusal(domain)
      pin = @pinned.find { |d, _| d == domain || domain.end_with?(".#{d}") }
      return nil unless pin

      sigs = @fields.select { |name, _, _| name.casecmp?("DKIM-Signature") }.map { |_, value, _| tags(value) }
      aligned = sigs.select { |t| t["d"].present? && aligned?(t["d"].downcase, domain) }
      return "no DKIM-Signature for #{domain} under a pinned selector (#{pin.last.join(', ')})" if aligned.empty?

      stray = aligned.map { |t| t["s"].to_s.downcase }.reject { |s| pin.last.include?(s) }
      return "signed for #{domain} under selector #{stray.uniq.join(', ')}, not the pinned #{pin.last.join(', ')}" if stray.any?

      nil
    end

    def tags(value)
      value.to_s.split(";").filter_map do |pair|
        k, v = pair.split("=", 2)
        [ k.to_s.strip.downcase, v.to_s.gsub(/\s+/, "") ] if v
      end.to_h
    end

    def signing_domain(result)
      d = result[:props]["header.d"].presence || result[:props]["header.i"].to_s.split("@", 2).last.presence
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
