# frozen_string_literal: true

require "time"

module DomainCutover
  # The four phases of a Pro-tier domain move, plus the Workspace mail step.
  #
  #   plan      read the registry (RDAP), the DS and every record (DoH); add the
  #             bare domain to Heroku; create the Cloudflare zone; copy every record
  #             exactly and DNS only; add the app records; SSL Full (strict); write
  #             the www -> bare redirect DISABLED; print the registrar guide.
  #   verify    the registry's nameservers, zone activation, DoH parity with the
  #             snapshot, the bare domain resolving publicly, Heroku ACM. Notes the
  #             first time the registry shows Cloudflare's nameservers.
  #   finalize  refuses until SIX HOURS after that, then sets APP_HOST to the bare
  #             domain, enables the redirect and re-verifies.
  #   status    the phase, the timestamps, the next action and when it is allowed.
  #   workspace Google Workspace's mail records, written into the zone.
  #
  # WHY FINALIZE WAITS SIX HOURS. Resolvers keep the OLD nameservers cached for up
  # to the TLD's NS TTL, 21600 s, and the old zone keeps answering them. Enabling
  # the redirect or moving APP_HOST inside that window lets a mixed cache loop
  # (new www -> bare, old bare -> registrar forwarding -> www) or send people to a
  # bare domain the old zone does not have. Measured live on 2026-10-13.
  #
  # Every write goes through #apply: printed, run, and READ BACK; under --dry-run
  # it is only printed, and nothing is saved.
  class Runner
    NS_CACHE_SECONDS = 21_600
    # Same pattern as DnsHost::PROVIDERS["cloudflare"] (app/models/dns_host.rb),
    # which needs Rails to load; test/lib/domain_cutover_test.rb pins the two equal.
    CLOUDFLARE_NS = /(\A|\.)ns\.cloudflare\.com\z/

    def initialize(app:, domain:, cloudflare:, heroku:, doh:, rdap:, store:, out: $stdout, dry_run: false,
                   clock: -> { Time.now.utc })
      @app = app
      @domain = Records.name(domain)
      @cf = cloudflare
      @heroku = heroku
      @doh = doh
      @rdap = rdap
      @store = store
      @out = out
      @dry_run = dry_run
      @clock = clock
    end

    def self.cloudflare_ns?(nameservers)
      list = Array(nameservers).map { |n| Records.name(n) }
      list.any? && list.all? { |n| n.match?(CLOUDFLARE_NS) }
    end

    # ── plan ─────────────────────────────────────────────────────────────────
    def plan(to: "alex", names: [])
      raise Abort, "--to must be one of #{Guide::AUDIENCES.join(', ')}. Nothing ran." unless Guide::AUDIENCES.include?(to)

      state = @store.load(@domain)
      if state && state["phase"] == "finalized"
        raise Abort, "#{@domain} is already finalized (#{state['finalized_at']}); plan would disable its live redirect. Nothing ran."
      end

      banner("plan")
      info = @rdap.lookup(@domain)
      ds = info.delegation_signed || @doh.ds_published?(@domain)
      say "registrar:   #{info.registrar || 'unknown'} (guide: #{Guide.key_for(info.registrar_key)})"
      say "registry NS: #{info.nameservers.join(', ')}"
      say "DS:          #{ds ? 'PUBLISHED: the guide schedules a DNSSEC-off outage' : 'none'}"

      zone = @cf.find_zone(@domain)
      if zone.nil? && (info.registrar_key == "cloudflare" || self.class.cloudflare_ns?(info.nameservers))
        raise Abort, "#{@domain} is already on Cloudflare, in an account our token cannot reach " \
                     "(registrar: #{info.registrar}). A client's domain must be registered anywhere except " \
                     "Cloudflare Registrar. Nothing was written."
      end

      snapshot = snapshot(Records::DEFAULT_NAMES.map { |n| fqdn(n) } + names.map { |n| fqdn(n) })

      target = heroku_target
      zone_id, nameservers = ensure_zone(zone)

      current = zone_id ? @cf.records(zone_id) : []
      imported = current.map(&:name).uniq - snapshot.map(&:name).uniq
      unless imported.empty?
        say "reading #{imported.size} more name(s) Cloudflare's import found: #{imported.join(', ')}"
        snapshot = (snapshot + snapshot(imported)).uniq(&:key)
      end
      say "snapshot:    #{snapshot.size} record(s)"
      snapshot.each { |r| say "  #{r}" }

      desired = Records.desired(@domain, snapshot, target)
      reconcile(zone_id, desired, current)
      set_ssl(zone_id)
      write_redirect(zone_id, enabled: false)

      state = {
        "app" => @app, "domain" => @domain, "phase" => "planned", "planned_at" => now.iso8601,
        "registrar" => info.registrar, "registrar_key" => info.registrar_key, "ds_at_plan" => ds,
        "zone_id" => zone_id, "nameservers" => nameservers, "heroku_target" => target,
        "snapshot" => snapshot.map { |r| r.to_h.except(:id, :proxied) },
        # A re-plan keeps what verify already saw: the six-hour clock does not restart.
        "ns_seen_at" => state&.dig("ns_seen_at")
      }
      save(state)

      say ""
      say Guide.new(registrar_key: info.registrar_key, registrar: info.registrar, domain: @domain,
                    nameservers: nameservers, ds_present: ds, to: to).render
      say ""
      say "next: #{ds ? 'DNSSEC off at the registrar (scheduled outage), then' : 'paste the nameservers, then'} " \
          "bin/domain-cutover #{@app} #{@domain} verify"
      state
    end

    # ── verify ───────────────────────────────────────────────────────────────
    # Returns true when every check is green.
    def verify(state = load!)
      banner("verify")
      checks = []
      info = @rdap.lookup(@domain)
      ds = info.delegation_signed || @doh.ds_published?(@domain)
      on_cf = same_ns?(info.nameservers, state["nameservers"])
      checks << check("registry NS are Cloudflare's", on_cf, info.nameservers.join(", "))
      checks << check("no DS published", !ds, ds ? "the TLD still serves a DS; wait for it (TTL 3600)" : "clear")
      if !on_cf && state["ns_seen_at"]
        say "the registry no longer shows Cloudflare's nameservers: the six-hour clock resets"
        state["ns_seen_at"] = nil
      elsif on_cf && state["ns_seen_at"].nil?
        state["ns_seen_at"] = now.iso8601
        say "first saw Cloudflare's nameservers at the registry: #{state['ns_seen_at']}"
      end

      zone = @cf.zone(state["zone_id"])
      if zone["status"] != "active" && on_cf
        apply(@cf.activation_check(state["zone_id"])) { zone = @cf.zone(state["zone_id"]) }
      end
      checks << check("zone active", zone["status"] == "active", zone["status"].to_s)

      ns_answers = @doh.both(@domain, "NS")
      servfail = ns_answers.select(&:servfail?).map(&:resolver)
      checks << check("no SERVFAIL", servfail.empty?, servfail.empty? ? "both resolvers answer" : "SERVFAIL on #{servfail.join(', ')}: outage")
      public_cf = ns_answers.all? { |a| a.status.zero? && same_ns?(a.records.map(&:content), state["nameservers"]) }
      checks << check("resolvers see Cloudflare's NS", public_cf,
                      ns_answers.map { |a| "#{a.resolver}: #{a.records.map(&:content).join(' ')}" }.join("; "))

      mismatches = parity(state)
      checks << check("public DNS answers the zone (DoH)", mismatches.empty?,
                      mismatches.empty? ? "every zone record answers" : mismatches.first(5).join("; "))

      bare = @doh.both(@domain, "A").all? { |a| a.status.zero? && a.records.any? }
      checks << check("#{@domain} resolves publicly", bare, bare ? "A records on both resolvers" : "not yet")

      row = @heroku.domain(@app, @domain)
      acm = row && row["acm_status"]
      if bare && acm != Heroku::ISSUED && row
        apply(@heroku.acm_refresh(@app)) { acm = @heroku.domain(@app, @domain)&.dig("acm_status") }
      end
      checks << check("Heroku ACM for #{@domain}", acm == Heroku::ISSUED, acm.to_s.empty? ? "no domain row" : acm)

      green = checks.all? { |c| c[:ok] }
      state["last_verify"] = { "at" => now.iso8601, "green" => green, "ds" => ds, "registry_on_cloudflare" => on_cf,
                               "acm" => acm, "zone" => zone["status"] }
      state["phase"] = "verified" if green && state["phase"] == "planned"
      save(state)
      say ""
      say next_action(state)
      green
    end

    # ── finalize ─────────────────────────────────────────────────────────────
    def finalize
      state = load!
      banner("finalize")
      seen = state["ns_seen_at"] && Time.iso8601(state["ns_seen_at"])
      unless seen
        raise Abort, "finalize REFUSED: verify has not yet seen Cloudflare's nameservers at the registry. " \
                     "Run verify after the nameservers are saved. Nothing was written."
      end
      allowed = seen + NS_CACHE_SECONDS
      if now < allowed
        raise Abort, "finalize REFUSED until #{allowed.iso8601} (registry NS change seen #{seen.iso8601} + 6h): " \
                     "resolvers may still cache the old nameservers, and a redirect now can loop. Nothing was written."
      end

      unless same_ns?(@rdap.lookup(@domain).nameservers, state["nameservers"])
        raise Abort, "finalize REFUSED: the registry no longer shows Cloudflare's nameservers. Run verify. Nothing was written."
      end

      zone = @cf.zone(state["zone_id"])
      raise Abort, "finalize REFUSED: zone is #{zone['status']}, not active. Run verify. Nothing was written." unless zone["status"] == "active"

      acm = @heroku.domain(@app, @domain)&.dig("acm_status")
      unless acm == Heroku::ISSUED
        raise Abort, "finalize REFUSED: Heroku ACM for #{@domain} reads #{acm.inspect}, not #{Heroku::ISSUED.inspect}. " \
                     "APP_HOST moves only after the certificate issues. Run verify. Nothing was written."
      end

      move_app_host
      write_redirect(state["zone_id"], enabled: true)
      state["phase"] = "finalized"
      state["finalized_at"] = now.iso8601
      save(state)
      green = verify(state)
      say(green ? "finalized: #{@domain} serves the app; www 301s to it" : "finalized, but verify is not all green: read above")
      green
    end

    # ── workspace ────────────────────────────────────────────────────────────
    def workspace(verification: nil, rua: nil, dkim: nil, replace_mail: false)
      state = load!
      banner("workspace")
      zone_id = state["zone_id"]
      current = @cf.records(zone_id)
      result = Workspace.plan(@domain, current, verification: verification, rua: rua, dkim: dkim,
                                                replace_mail: replace_mail)
      unless result[:conflicts].empty?
        raise Abort, "workspace REFUSED: existing mail records differ:\n  #{result[:conflicts].join("\n  ")}\n" \
                     "Pass --replace-mail to overwrite them. Nothing was written."
      end
      say "verification: none supplied (pass --verification <value> from Google's signup)" if verification.nil?
      result[:changes].each do |change|
        write = case change.op
                when :create then @cf.create_record(zone_id, change.record)
                when :replace then @cf.replace_record(zone_id, change.record, change.content)
                when :delete then @cf.delete_record(zone_id, change.record, why: "not Google's MX (--replace-mail)")
                end
        apply(write)
      end
      say "mail records already in place; nothing to write" if result[:changes].empty?
      unless @dry_run || result[:changes].empty?
        after = @cf.records(zone_id)
        want = result[:changes].reject { |c| c.op == :delete }.map do |c|
          c.op == :replace ? c.record.dup.tap { |r| r.content = c.content } : c.record
        end
        lost = want.reject { |w| after.any? { |r| r.key == w.key } }
        raise Abort, "read-back: missing after write: #{lost.map(&:to_s).join('; ')}" unless lost.empty?

        say "read back: #{want.size} mail record(s) present"
      end
      result[:notes].each { |n| say n }
      state["workspace_at"] = now.iso8601
      save(state)
      result
    end

    # ── status ───────────────────────────────────────────────────────────────
    def status
      state = @store.load(@domain)
      unless state
        say "#{@domain}: no cutover planned. Next: bin/domain-cutover #{@app} #{@domain} plan --dry-run"
        return nil
      end
      say "#{@domain} (#{state['app']}): #{state['phase']}"
      say "  registrar:     #{state['registrar']}"
      say "  nameservers:   #{Array(state['nameservers']).join(', ')}"
      say "  planned:       #{state['planned_at']}"
      say "  registry NS:   #{state['ns_seen_at'] ? "Cloudflare's since #{state['ns_seen_at']}" : 'not yet seen'}"
      say "  finalize from: #{finalize_at(state)&.iso8601 || 'after verify sees the nameservers + 6h'}"
      say "  last verify:   #{state.dig('last_verify', 'at') || 'never'}#{state.dig('last_verify', 'green') ? ' (green)' : ''}"
      say "  finalized:     #{state['finalized_at'] || '-'}"
      say next_action(state)
      state
    end

    def finalize_at(state)
      state["ns_seen_at"] && Time.iso8601(state["ns_seen_at"]) + NS_CACHE_SECONDS
    end

    def next_action(state)
      cmd = "bin/domain-cutover #{@app} #{@domain}"
      lv = state["last_verify"] || {}
      if state["phase"] == "finalized"
        "next: #{cmd} workspace (if mail moves to Google), then DNSSEC back on from Cloudflare after a day green (domain-dns step 6)"
      elsif state["ns_seen_at"]
        at = finalize_at(state)
        now >= at ? "next: #{cmd} finalize (allowed now)" : "next: #{cmd} verify until green; #{cmd} finalize allowed at #{at.iso8601}"
      elsif lv["ds"] || (lv.empty? && state["ds_at_plan"])
        "next: registrar: DNSSEC off (scheduled outage), then #{cmd} verify until the DS clears; paste the nameservers at once"
      else
        "next: registrar: paste the nameservers #{Array(state['nameservers']).join(' + ')} now, then #{cmd} verify"
      end
    end

    private

    def now = @clock.call

    def fqdn(rel) = rel.to_s.empty? ? @domain : (rel.end_with?(@domain) ? Records.name(rel) : "#{Records.name(rel)}.#{@domain}")

    def say(line) = @out.puts(line)

    def banner(phase) = say("domain-cutover #{phase}: #{@app} #{@domain}#{@dry_run ? ' (DRY RUN: no writes)' : ''}")

    def check(name, ok, detail)
      say "  [#{ok ? ' ok ' : 'WAIT'}] #{name}: #{detail}"
      { name: name, ok: ok }
    end

    def same_ns?(a, b)
      norm = ->(l) { Array(l).map { |n| Records.name(n) }.sort }
      !Array(a).empty? && norm.call(a) == norm.call(b)
    end

    def load!
      @store.load(@domain) || raise(Abort, "no cutover state for #{@domain}: run `bin/domain-cutover #{@app} #{@domain} plan` first")
    end

    def save(state)
      return state if @dry_run

      @store.save(@domain, state)
    end

    # Print, run and read back one write. Under --dry-run: print only.
    def apply(write)
      if @dry_run
        say "  WOULD #{write}"
        return nil
      end
      say "  write #{write}"
      api = write.api == :heroku ? @heroku : @cf
      result = api.perform(write)
      yield(result) if block_given?
      result
    end

    # Every snapshot name and type, read on both resolvers and unioned: a record
    # one resolver has and the other lacks is kept (losing a record drops mail;
    # an extra one costs nothing) and reported. A SERVFAIL stops the plan: an
    # outage is in progress and nothing read from it can be trusted.
    def snapshot(names)
      records = []
      names.uniq.each do |name|
        types = name == @domain ? %w[A AAAA MX TXT CAA] : %w[CNAME A AAAA MX TXT CAA]
        types.each do |type|
          answers = @doh.both(name, type)
          failed = answers.select(&:servfail?)
          unless failed.empty?
            raise Abort, "#{name} #{type} answers SERVFAIL on #{failed.map(&:resolver).join(', ')}: an outage is in " \
                         "progress (DNSSEC?). plan reads nothing from a failing domain. Nothing was written."
          end
          sets = answers.map { |a| a.records.map(&:key).sort }
          say "  note: resolvers disagree on #{name} #{type}; keeping both answers" if sets.uniq.size > 1
          records.concat(answers.flat_map(&:records))
          # A CNAME owns its name: nothing else can live there.
          break if type == "CNAME" && answers.any? { |a| a.records.any? }
        end
      end
      records.uniq(&:key)
    end

    def heroku_target
      row = @heroku.domain(@app, @domain)
      if row.nil?
        apply(@heroku.add_domain(@app, @domain)) { row = @heroku.domain(@app, @domain) }
        return "<herokudns target from domains:add>" if @dry_run
        raise Abort, "read-back: Heroku has no #{@domain} on #{@app} after the add" if row.nil?
      end
      target = row["cname"].to_s
      raise Abort, "Heroku's #{@domain} row on #{@app} has no DNS target" if target.empty?

      say "heroku:      #{@domain} -> #{target}"
      target
    end

    def ensure_zone(zone)
      if zone
        say "zone:        exists (#{zone['id']}, #{zone['status']})"
        return [zone["id"], zone["name_servers"]]
      end
      created = apply(@cf.create_zone(@domain))
      return [nil, ["<assigned on create>", "<assigned on create>"]] if @dry_run

      back = @cf.zone(created["id"])
      raise Abort, "read-back: zone #{created['id']} does not read back as #{@domain}" unless Records.name(back["name"]) == @domain

      say "zone:        created (#{back['id']}); nameservers #{back['name_servers'].join(', ')}"
      [back["id"], back["name_servers"]]
    end

    # Deletes first (a CNAME cannot share its name), then proxy fixes, then
    # creates; then a fresh re-list must hold every desired record.
    def reconcile(zone_id, desired, current)
      diff = Records.reconcile(desired, current)
      say "records:     #{diff[:create].size} to create, #{diff[:update].size} to fix, #{diff[:delete].size} to delete"
      diff[:delete].each { |r| apply(@cf.delete_record(zone_id, r)) }
      diff[:update].each { |r| apply(@cf.update_record(zone_id, r)) }
      diff[:create].each { |r| apply(@cf.create_record(zone_id || "<zone-id>", r)) }
      diff[:extra].each { |r| say "  kept (Cloudflare's import found it; the DoH snapshot did not): #{r}" }
      return if @dry_run

      missing = Records.missing(desired, @cf.records(zone_id))
      raise Abort, "read-back: the zone lacks #{missing.map(&:to_s).join('; ')}" unless missing.empty?

      say "read back:   all #{desired.size} desired record(s) present"
    end

    def set_ssl(zone_id)
      apply(@cf.set_ssl_strict(zone_id || "<zone-id>"))
      return if @dry_run

      value = @cf.ssl(zone_id)
      raise Abort, "read-back: SSL reads #{value.inspect}, not \"strict\"" unless value == "strict"
    end

    def write_redirect(zone_id, enabled:)
      rules = zone_id ? @cf.redirect_rules(zone_id) : []
      apply(@cf.put_redirect(zone_id || "<zone-id>", @domain, rules, enabled: enabled))
      return if @dry_run

      ours = @cf.redirect_rules(zone_id).find { |r| r["ref"] == Cloudflare::REDIRECT_REF }
      unless ours && ours["enabled"] == enabled && ours["expression"].to_s.include?("www.#{@domain}")
        raise Abort, "read-back: the www redirect does not read back enabled=#{enabled}"
      end
    end

    # APP_HOST becomes the bare domain. When the app also keeps an APP_HOSTS
    # allow-list, the bare and www hosts are added to it in the same write, so
    # the bare domain is never refused by host authorization.
    def move_app_host
      vars = @heroku.config_vars(@app)
      want = { "APP_HOST" => @domain }
      if vars.key?("APP_HOSTS")
        hosts = vars["APP_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?)
        merged = (hosts + [@domain, "www.#{@domain}"]).uniq
        want["APP_HOSTS"] = merged.join(",") unless merged == hosts
      end
      want.reject! { |k, v| vars[k] == v }
      if want.empty?
        say "  APP_HOST already #{@domain}"
        return
      end
      apply(@heroku.set_config(@app, want))
      return if @dry_run

      settled = @heroku.config_vars_settled(@app, want)
      wrong = want.reject { |k, v| settled[k] == v }.keys
      raise Abort, "read-back: #{wrong.join(', ')} did not settle on #{@app}" unless wrong.empty?

      say "read back:   #{want.keys.join(', ')} settled on #{@app}"
    end

    # Zone records the public resolvers do not yet answer as the zone holds them.
    # Read against the zone, not the plan's snapshot, so a later `workspace` change
    # is not a mismatch; plan already proved the zone holds the snapshot. The app
    # records and anything proxied are skipped: the edge answers for those.
    def parity(state)
      zone = @cf.records(state["zone_id"]).reject do |r|
        r.proxied || ([@domain, "www.#{@domain}"].include?(r.name) && r.type == "CNAME")
      end
      zone.group_by(&:group).filter_map do |(name, type), want|
        answers = @doh.both(name, type)
        wrong = answers.reject { |a| a.records.map(&:key).sort == want.map(&:key).sort }
        next if wrong.empty?

        "#{name} #{type} differs on #{wrong.map(&:resolver).join('+')}"
      end
    end
  end
end
