# frozen_string_literal: true

require "time"

module DomainRegister
  # check, register and status. Every refusal is decided from a domain-check made
  # IMMEDIATELY before the registration POST, never from an earlier check or a
  # remembered price: a quote can change between Alex's OK and the purchase, and
  # the OK covered one price.
  class Runner
    # Cloudflare's API registers no premium domain today ("do not call this
    # endpoint if domain-check returns tier: premium"). --premium is the explicit
    # fee acknowledgement the brief asks for; while this is false, a premium
    # domain still stops here, acknowledged or not, and is bought in the dashboard.
    PREMIUM_VIA_API = false

    PRICE = /\A\d+(\.\d{1,2})?\z/
    DATED = /\b20\d\d-\d\d-\d\d\b/
    CURRENCY = "USD"
    TERMINAL = %w[succeeded failed].freeze
    WAITING = %w[pending in_progress blocked].freeze

    def initialize(registrar:, ledger:, zone_client: nil, out: $stdout, sleeper: ->(s) { sleep(s) },
                   clock: -> { Time.now.utc }, actor: ENV.fetch("USER", "unknown"),
                   poll_interval: 5, poll_timeout: 600, zone_attempts: 6, zone_interval: 10)
      @registrar = registrar
      @ledger = ledger
      @zone_client = zone_client # -> { DomainCutover::Cloudflare }, built only after a purchase
      @out = out
      @sleeper = sleeper
      @clock = clock
      @actor = actor
      @poll_interval = poll_interval
      @poll_timeout = poll_timeout
      @zone_attempts = zone_attempts
      @zone_interval = zone_interval
    end

    # ── check (read-only) ────────────────────────────────────────────────────
    def check(domains)
      quotes = @registrar.check(domains)
      quotes.each { |q| say q.to_s }
      missing = domains - quotes.map(&:name)
      missing.each { |d| say "#{d}  NO ANSWER (Cloudflare returned no row for it)" }
      quotes
    end

    # Every reason this purchase must not happen, from a fresh quote. Empty means go.
    def self.refusals(quote, price:, ok:, premium:)
      reasons = []
      if quote.nil?
        reasons << "Cloudflare returned no domain-check row for this domain"
        return reasons
      end

      if quote.premium?
        if !premium
          reasons << "#{quote.name} is PREMIUM (#{quote.price_line}): pass --premium to acknowledge the premium fee"
        elsif !PREMIUM_VIA_API
          reasons << "#{quote.name} is PREMIUM and Cloudflare's API does not register premium domains yet: " \
                     "Alex buys it in the dashboard"
        end
      elsif !quote.registrable
        reasons << "#{quote.name} is not available: #{quote.reason || 'no reason given'} (#{quote.reason_text})"
      end

      if quote.registrable || quote.premium?
        if quote.registration.nil?
          reasons << "Cloudflare quoted no registration price"
        elsif quote.currency != CURRENCY
          reasons << "Cloudflare quoted #{quote.currency}, not #{CURRENCY}"
        end
      end

      if price.to_s.strip.empty?
        reasons << "no --price: pass the exact USD registration price Alex approved"
      elsif !price.to_s.strip.match?(PRICE)
        reasons << "--price #{price.inspect} is not a USD amount like 10.46"
      elsif quote.registration && BigDecimal(price.to_s.strip) != quote.registration
        reasons << "price changed: Cloudflare quotes #{CURRENCY} #{Quote.format(quote.registration)} now, " \
                   "Alex approved #{CURRENCY} #{Quote.format(BigDecimal(price.to_s.strip))}: ask him again"
      end

      if ok.to_s.strip.empty?
        reasons << "no --ok: quote Alex's own words approving this domain at this price, with the date"
      elsif !ok.to_s.match?(DATED)
        reasons << "--ok carries no date: quote Alex's words with the date, e.g. \"buy it, 2026-10-19\""
      end

      reasons
    end

    # ── register (spends money unless dry_run) ───────────────────────────────
    # A real run holds the ledger's lock from its first ledger read to its last
    # write (Ledger#exclusively); a dry run writes nothing and takes no lock.
    def register(domain, price:, ok:, premium: false, dry_run: false)
      return register_run(domain, price: price, ok: ok, premium: premium, dry_run: true) if dry_run

      @ledger.exclusively("run register for #{domain}") do
        register_run(domain, price: price, ok: ok, premium: premium, dry_run: false)
      end
    end

    def register_run(domain, price:, ok:, premium:, dry_run:)
      banner(dry_run ? "register --dry-run (spends nothing)" : "register")
      quote = @registrar.check([domain]).find { |q| q.name == domain }
      say "fresh check: #{quote || "#{domain}  NO ANSWER"}"
      refusals = self.class.refusals(quote, price: price, ok: ok, premium: premium)

      return plan(domain, refusals + [dangling_refusal(domain)].compact) if dry_run

      refusals << dangling_refusal(domain)
      refusals.compact!
      unless refusals.empty?
        raise Abort, "REFUSED, nothing was bought:\n#{refusals.map { |r| "  - #{r}" }.join("\n")}"
      end

      ensure_never_registered!(domain)

      record("authorized", domain, quote, ok: ok)
      say "registering #{domain} for #{CURRENCY} #{Quote.format(quote.registration)} " \
          "(auto-renew ON at #{CURRENCY} #{Quote.format(quote.renewal)}/yr, WHOIS redaction ON)"
      workflow = begin
        @registrar.register(domain)
      rescue HttpError => e
        raise ambiguous!(domain, quote, e) unless e.rejected?

        record("failed", domain, quote, failure: "rejected", error: e.message)
        raise
      rescue Abort => e # NoAnswer, and anything else that left no answer
        raise ambiguous!(domain, quote, e)
      end

      final = begin
        poll(domain, workflow)
      rescue Abort => e
        raise ambiguous!(domain, quote, e)
      end

      case final["state"]
      when "succeeded"
        record("registered", domain, quote, registration: final.dig("context", "registration"))
        say "REGISTERED #{domain}#{expiry(final)}"
        say "ledger: #{@ledger.path}"
        zone = prove_zone(domain)
        next_step(domain)
        zone ? true : false
      when "failed"
        record("failed", domain, quote, failure: "workflow", workflow: final)
        raise Abort, outcome_message(domain, final)
      else
        record("pending", domain, quote, workflow: final)
        raise Abort, outcome_message(domain, final)
      end
    end

    # How long after an `authorized` line a "no workflow" answer from status is
    # trusted to mean nothing was bought (Cloudflare's synchronous window is 10s).
    SETTLE_SECONDS = 900

    def self.unknown_message(domain, why)
      "#{domain}: the purchase request was sent and no clear answer came back (#{why}). " \
        "Money MAY have moved. Run bin/domain-register status #{domain}; do NOT re-run register."
    end

    # ── status (reads Cloudflare; writes ledger closing lines) ────────────────
    # Not read-only: an open authorization the workflow has settled is closed in
    # the ledger here (#reconcile, #close_unbought), so status holds the lock too.
    def status(domain)
      @ledger.exclusively("run status for #{domain}") { status_run(domain) }
    end

    def status_run(domain)
      workflow = @registrar.existing_workflow(domain)
      open = @ledger.open_authorization(domain)
      if workflow.nil?
        say "#{domain}: no registration workflow at Cloudflare (nothing was bought through the API)"
        close_unbought(domain, open) if open
        return nil
      end
      reconcile(domain, open, workflow) if open
      say "#{domain}: #{workflow['state'] || 'unknown'}#{workflow['completed'] ? ' (completed)' : ''}#{expiry(workflow)}"
      error = workflow["error"]
      say "  error: #{error['code']} #{error['message']}" if error
      action = workflow.dig("context", "action")
      say "  action required: #{action}" if action
      workflow
    end

    # Follow a workflow to a terminal state. 201 arrives completed; 202 is polled.
    # `action_required` stops at once (a person must act); `blocked` keeps polling,
    # as Cloudflare advises.
    def poll(domain, workflow)
      deadline = @clock.call + @poll_timeout
      current = workflow
      loop do
        state = current["state"]
        return current if TERMINAL.include?(state) || current["completed"] == true
        return current if state == "action_required"

        unless WAITING.include?(state)
          raise Abort, "#{domain}: unknown workflow state #{state.inspect}; read it with " \
                       "bin/domain-register status #{domain}"
        end
        return current if @clock.call >= deadline

        say "  #{state}..."
        @sleeper.call(@poll_interval)
        current = @registrar.status(domain)
      end
    end

    private :register_run, :status_run

    private

    # LEDGER FIRST: an authorization nothing has closed means an earlier run may
    # have bought it.
    def dangling_refusal(domain)
      open = @ledger.open_authorization(domain)
      return nil unless open

      "the ledger holds an open authorization for #{domain} from #{open['at']} (by #{open['by']}): an " \
        "earlier purchase may have gone through. Run bin/domain-register status #{domain} first"
    end

    # STATUS FIRST: proceed only on Cloudflare's documented "No workflow found".
    def ensure_never_registered!(domain)
      workflow = begin
        @registrar.existing_workflow(domain)
      rescue Abort => e
        raise Abort, "REFUSED, nothing was bought: could not confirm that no registration exists for " \
                     "#{domain} (#{e.message}). Try again later; bin/domain-register status #{domain}"
      end
      return if workflow.nil?

      raise Abort, "REFUSED, nothing was bought: a registration for #{domain} already exists at Cloudflare " \
                   "(state #{workflow['state'] || 'unknown'}). Read it with bin/domain-register status #{domain}"
    end

    # The POST or the poll left no clear outcome: ledger `unknown`, never `failed`.
    def ambiguous!(domain, quote, error)
      record("unknown", domain, quote, error: error.message)
      NoAnswer.new(self.class.unknown_message(domain, error.message))
    end

    def reconcile(domain, open, workflow)
      quote = quote_from(open)
      case workflow["state"]
      when "succeeded"
        record("registered", domain, quote, registration: workflow.dig("context", "registration"), via: "status")
        say "ledger: closed the #{open['at']} authorization as registered"
      when "failed"
        record("failed", domain, quote, failure: "workflow", workflow: workflow, via: "status")
        say "ledger: closed the #{open['at']} authorization as failed (nothing was bought)"
      end
    end

    def close_unbought(domain, open)
      age = @clock.call - Time.iso8601(open["at"])
      if age >= SETTLE_SECONDS
        record("no_workflow", domain, quote_from(open), via: "status")
        say "ledger: closed the #{open['at']} authorization: no workflow #{(age / 60).floor} minutes later, nothing was bought"
      else
        say "ledger: the #{open['at']} authorization stays open until #{SETTLE_SECONDS / 60} minutes have passed; " \
            "run status again then"
      end
    end

    def quote_from(entry)
      Quote.new(name: entry["domain"], currency: entry["currency"],
                registration: Quote.money(entry["price"]), renewal: Quote.money(entry["renewal"]))
    end

    def plan(domain, refusals)
      say ""
      if refusals.empty?
        say "PLAN (all gates pass): the real run would"
      else
        say "WOULD REFUSE:"
        refusals.each { |r| say "  - #{r}" }
        say ""
        say "and, once those clear, would"
      end
      say "  1. refuse on an open ledger authorization, then GET registration-status and refuse unless " \
          "Cloudflare answers \"No workflow found\"; then append 'authorized' to #{@ledger.path}"
      say "  2. CLOUDFLARE POST /accounts/<account>/registrar/registrations #{JSON.generate(@registrar.registration_body(domain))}"
      say "  3. poll registration-status every #{@poll_interval}s, up to #{@poll_timeout}s"
      say "  4. read the zone back (same token) and print the domain-dns next step"
      say "Nothing was bought; no ledger line was written."
      refusals.empty?
    end

    def prove_zone(domain)
      client = begin
        @zone_client&.call
      rescue Abort => e
        say "zone proof: could not build the zone reader (#{e.message}); the domain IS registered"
        return nil
      end
      unless client
        say "zone proof: skipped (no zone reader); check the zone by hand in the dashboard"
        return nil
      end

      @zone_attempts.times do |i|
        zone = begin
          client.find_zone(domain)
        rescue Abort => e
          say "zone proof: #{e.message}"
          nil
        end
        if zone
          say "zone: #{zone['name']} is in our account (id #{zone['id']}, status #{zone['status']}, " \
              "nameservers #{Array(zone['name_servers']).join(', ')})"
          return zone
        end
        @sleeper.call(@zone_interval) if i < @zone_attempts - 1
      end
      say "WARNING: no zone for #{domain} in our Cloudflare account yet. Cloudflare Registrar creates it; " \
          "re-check in a few minutes in the dashboard before running domain-dns."
      nil
    end

    def next_step(domain)
      say ""
      say "NEXT: Steffon's domain-dns SOP (docs/agents/agents/steffon/sops/domain-dns.md) for #{domain}."
      say "  The zone is already on Cloudflare with Cloudflare's nameservers: no registrar move, no 6-hour wait."
    end

    def outcome_message(domain, workflow)
      state = workflow["state"] || "unknown"
      case state
      when "failed"
        error = workflow["error"] || {}
        hint = Registrar.prerequisite_for("#{error['code']} #{error['message']}")
        msg = "#{domain}: registration FAILED: #{error['code']} #{error['message']}"
        hint ? "#{msg}\n  -> #{hint}" : msg
      when "action_required"
        "#{domain}: Cloudflare needs a person: #{workflow.dig('context', 'action') || 'see the dashboard'}. " \
          "Alex acts in the dashboard; then bin/domain-register status #{domain}"
      else
        "#{domain}: still #{state} after #{@poll_timeout}s. The purchase may complete on its own: " \
          "bin/domain-register status #{domain} (do NOT re-run register)"
      end
    end

    def record(event, domain, quote, **extra)
      @ledger.append({ "event" => event, "domain" => domain, "at" => @clock.call.utc.iso8601,
                       "by" => @actor, "currency" => quote.currency,
                       "price" => Quote.format(quote.registration), "renewal" => Quote.format(quote.renewal),
                       "auto_renew" => true, "privacy_mode" => "redaction" }.merge(extra.transform_keys(&:to_s)))
    end

    def expiry(workflow)
      expires = workflow.dig("context", "registration", "expires_at")
      expires ? ", expires #{expires}" : ""
    end

    def banner(text) = say("== domain-register #{text}")
    def say(text) = @out.puts(text)
  end
end
