# frozen_string_literal: true

module DomainCutover
  # The Google Workspace mail records for a domain already on Cloudflare: the
  # verification TXT, Google's MX set, ONE SPF TXT (merged with any include it
  # already carries, such as Resend's), DMARC at p=none and, when its value is
  # supplied, DKIM. Pure: it reads the zone's records and answers the changes.
  #
  # It never overwrites mail records that differ (another MX, a different
  # DMARC or DKIM) without `replace_mail`: a wrong overwrite there drops or
  # spam-folders mail silently. A conflict refuses the WHOLE step, so nothing is
  # half-written.
  module Workspace
    GOOGLE_MX = [[1, "aspmx.l.google.com"], [5, "alt1.aspmx.l.google.com"], [5, "alt2.aspmx.l.google.com"],
                 [10, "alt3.aspmx.l.google.com"], [10, "alt4.aspmx.l.google.com"]].freeze
    # Google's newer single-record form; a domain already on it is already Google's.
    GOOGLE_MX_SINGLE = [[1, "smtp.google.com"]].freeze
    SPF_INCLUDE = "include:_spf.google.com"
    DKIM_PROMPT = <<~TXT.freeze
      DKIM is one click in Google Admin, then one flag here:
        admin.google.com -> Apps -> Google Workspace -> Gmail -> Authenticate email
        -> Generate new record (2048-bit, prefix "google"); copy the TXT value, then run
        bin/domain-cutover <app> <domain> workspace --dkim "v=DKIM1; k=rsa; p=..."
        and press "Start authentication" in Google Admin once it resolves.
    TXT

    Change = Struct.new(:op, :record, :content, keyword_init: true) do
      def to_s
        case op
        when :create then "create #{record}"
        when :delete then "delete #{record}"
        when :replace then "replace #{record} -> #{content.inspect}"
        end
      end
    end

    module_function

    def spf?(rec) = rec.type == "TXT" && rec.content.downcase.start_with?("v=spf1")

    # The one SPF the domain should carry, given the one it has (nil when none).
    def merged_spf(existing)
      return "v=spf1 #{SPF_INCLUDE} ~all" if existing.nil?

      terms = existing.split(/\s+/).drop(1)
      return existing if terms.include?(SPF_INCLUDE)

      all = terms.find { |t| t.match?(/\A[+\-~?]?all\z/i) } || "~all"
      body = terms.reject { |t| t.match?(/\A[+\-~?]?all\z/i) }
      (["v=spf1"] + body + [SPF_INCLUDE, all]).join(" ")
    end

    # => { changes: [Change], conflicts: [String], notes: [String] }
    def plan(domain, current, verification:, rua: nil, dkim: nil, replace_mail: false)
      domain = Records.name(domain)
      changes = []
      conflicts = []
      notes = []
      apex = current.select { |r| r.name == domain }

      # Verification: additive, never conflicts (Google allows several).
      if verification
        value = verification.start_with?("google-site-verification=") ? verification : "google-site-verification=#{verification}"
        unless apex.any? { |r| r.type == "TXT" && r.content == value }
          changes << Change.new(op: :create, record: Record.new(name: domain, type: "TXT", content: value))
        end
      end

      # MX: Google's set, unless the domain already runs Google's MX.
      mx = apex.select { |r| r.type == "MX" }
      have = mx.map { |r| [r.priority, r.content] }.sort
      if have == GOOGLE_MX.sort || have == GOOGLE_MX_SINGLE
        notes << "MX already Google's; unchanged"
      else
        foreign = mx.reject { |r| GOOGLE_MX.include?([r.priority, r.content]) }
        if foreign.any? && !replace_mail
          conflicts << "MX: #{foreign.map(&:to_s).join(', ')} would be replaced by Google's set"
        else
          foreign.each { |r| changes << Change.new(op: :delete, record: r) }
          GOOGLE_MX.each do |pri, host|
            next if mx.any? { |r| r.priority == pri && r.content == host }

            changes << Change.new(op: :create, record: Record.new(name: domain, type: "MX", content: host, priority: pri))
          end
        end
      end

      # SPF: ONE TXT, merged.
      spfs = apex.select { |r| spf?(r) }
      if spfs.size > 1
        conflicts << "SPF: #{spfs.size} SPF records already (#{spfs.map(&:content).join(' | ')}); merge them by hand first"
      else
        want = merged_spf(spfs.first&.content)
        if spfs.empty?
          changes << Change.new(op: :create, record: Record.new(name: domain, type: "TXT", content: want))
        elsif spfs.first.content != want
          changes << Change.new(op: :replace, record: spfs.first, content: want)
        end
      end

      # DMARC and DKIM: one value each; a different one is a conflict.
      dmarc = "v=DMARC1; p=none; rua=#{rua || "mailto:team@#{domain}"}"
      single(changes, conflicts, current, "_dmarc.#{domain}", dmarc, /\Av=dmarc1/i, replace_mail, "DMARC")
      if dkim
        single(changes, conflicts, current, "google._domainkey.#{domain}", dkim, /\Av=dkim1/i, replace_mail, "DKIM")
      else
        notes << DKIM_PROMPT
      end

      { changes: changes, conflicts: conflicts, notes: notes }
    end

    def single(changes, conflicts, current, name, want, pattern, replace_mail, label)
      have = current.select { |r| r.name == name && r.type == "TXT" && r.content.match?(pattern) }
      return if have.any? { |r| r.content == want }

      if have.empty?
        changes << Change.new(op: :create, record: Record.new(name: name, type: "TXT", content: want))
      elsif replace_mail
        changes << Change.new(op: :replace, record: have.first, content: want)
        have.drop(1).each { |r| changes << Change.new(op: :delete, record: r) }
      else
        conflicts << "#{label}: #{name} holds #{have.map { |r| r.content.inspect }.join(', ')}, not #{want.inspect}"
      end
    end
  end
end
