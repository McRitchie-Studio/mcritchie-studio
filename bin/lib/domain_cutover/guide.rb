# frozen_string_literal: true

require "erb"

module DomainCutover
  # The registrar guide `plan` prints: the clicks the move needs at the domain's
  # registrar, and only those. Picked by the RDAP registrar; addressed to Alex
  # (our own domains) or to the client (a client-owned domain). The DNSSEC-off
  # step appears only when a DS is published, and it is called what it is: a
  # scheduled outage.
  #
  # Templates: bin/lib/domain_cutover/guides/<registrar>.md.erb. Squarespace's
  # navigation was walked live on 2026-10-13; the others are written from each
  # registrar's documentation and say "verify on first use".
  class Guide
    DIR = File.join(__dir__, "guides")
    AUDIENCES = %w[alex client].freeze
    # The console's name, which reads better than the registry's legal name
    # ("Squarespace Domains II LLC").
    LABELS = { "squarespace" => "Squarespace", "godaddy" => "GoDaddy", "namecheap" => "Namecheap",
               "porkbun" => "Porkbun", "cloudflare" => "Cloudflare" }.freeze
    OUTAGE = "about 15-20 minutes: measured 2026-10-13, validating resolvers failed from " \
             "11:52 to 12:05 MDT and Google's caches flapped until 12:13"

    def self.key_for(registrar_key)
      File.exist?(File.join(DIR, "#{registrar_key}.md.erb")) ? registrar_key : "other"
    end

    attr_reader :domain, :nameservers, :registrar, :to

    def initialize(registrar_key:, registrar:, domain:, nameservers:, ds_present:, to: "alex")
      raise Abort, "--to must be one of #{AUDIENCES.join(', ')}" unless AUDIENCES.include?(to)

      @key = self.class.key_for(registrar_key)
      @registrar = LABELS[@key] || (registrar.to_s.empty? ? "your registrar" : registrar)
      @domain = domain
      @nameservers = nameservers
      @ds_present = ds_present
      @to = to
      @step = 0
    end

    def ds_present? = @ds_present
    def client? = @to == "client"
    def us = client? ? "McRitchie Studio" : "Steffon"

    def render
      ERB.new(File.read(File.join(DIR, "#{@key}.md.erb")), trim_mode: "-").result(binding).gsub(/\n{3,}/, "\n\n")
    end

    # ── helpers the templates share ─────────────────────────────────────────
    def step(title)
      @step += 1
      "### Step #{@step}: #{title}"
    end

    def intro
      if client?
        "## Moving #{domain} to faster, protected DNS\n\n" \
          "You keep owning #{domain} at #{registrar}; nothing about the registration changes. " \
          "These steps point its DNS at Cloudflare, where #{us} manages it for you. " \
          "You only click at #{registrar}; we do everything else."
      else
        "## YOUR TURN: move #{domain} to Cloudflare DNS (registrar: #{registrar})"
      end
    end

    def ns_list = nameservers.map { |ns| "     #{ns}" }.join("\n")

    def confirm = "Check that the domain name on the page reads **#{domain}** before you save."

    def outage_warning
      "**This is a scheduled outage.** From the moment DNSSEC goes off until the registry drops " \
        "the old DS record (its TTL is one hour), #{domain} fails for validating resolvers: the site " \
        "is down and inbound mail is delayed. Expect #{OUTAGE}. Do it in a quiet window, " \
        "#{client? ? 'at a time we agree with you' : 'after you have said OK to the outage'}."
    end

    def after_dnssec
      "Then tell #{us} \"DNSSEC off\" and stop there: do **not** change the nameservers until " \
        "#{us} says the DS has cleared."
    end

    def ns_timing
      return "" unless ds_present?

      "Do this as soon as #{us} says the DS has cleared; waiting longer buys nothing."
    end

    def done = "Then tell #{us} \"nameservers saved\". #{us} takes it from there."

    def verify_note = "_Verify on first use: these clicks follow #{registrar}'s documentation, not a walked move._"
  end
end
