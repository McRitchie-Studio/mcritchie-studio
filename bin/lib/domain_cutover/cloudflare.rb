# frozen_string_literal: true

require "json"

module DomainCutover
  # Cloudflare's v4 API, with the agent token `cloudflare.studio.provision`
  # (Zone, Zone Settings, DNS and Dynamic URL Redirects read/write on every zone
  # in McRitchie Studio's account). Reads run at once; writes are built as Write
  # values and run by #perform, so --dry-run can print them instead.
  #
  # The token cannot reach a zone in another Cloudflare account, which is why a
  # CLIENT's domain must not sit on Cloudflare Registrar: that puts the zone in
  # the client's account, out of this command's reach.
  class Cloudflare
    BASE = "https://api.cloudflare.com/client/v4"
    REDIRECT_PHASE = "http_request_dynamic_redirect"
    REDIRECT_REF = "domain_cutover_www_to_bare"

    def initialize(transport, token:, account_id:)
      @transport = transport
      @token = token
      @account_id = account_id
    end

    attr_reader :account_id

    # ── reads ────────────────────────────────────────────────────────────────
    def find_zone(domain)
      result = get("/zones?#{URI.encode_www_form('name' => domain)}")
      Array(result).find { |z| Records.name(z["name"]) == Records.name(domain) }
    end

    def zone(id) = get("/zones/#{id}")

    def records(zone_id)
      rows = []
      page = 1
      loop do
        body = request(:get, "/zones/#{zone_id}/dns_records?per_page=500&page=#{page}")
        rows.concat(Array(body["result"]))
        total = body.dig("result_info", "total_pages").to_i
        break if page >= total || total.zero?

        page += 1
      end
      rows.map { |row| Records.from_cloudflare(row) }
    end

    def ssl(zone_id) = get("/zones/#{zone_id}/settings/ssl")["value"]

    # The redirect phase's rules, or [] when the zone has no entrypoint yet (404).
    def redirect_rules(zone_id)
      body = request(:get, "/zones/#{zone_id}/rulesets/phases/#{REDIRECT_PHASE}/entrypoint", allow: [404])
      Array(body.dig("result", "rules"))
    end

    # ── writes (built, not run) ──────────────────────────────────────────────
    def create_zone(domain)
      Write.new(api: :cloudflare, verb: :post, path: "/zones",
                body: { "name" => domain, "account" => { "id" => @account_id }, "type" => "full", "jump_start" => true },
                why: "create the zone (type full) and let Cloudflare import what it can find")
    end

    def create_record(zone_id, rec)
      Write.new(api: :cloudflare, verb: :post, path: "/zones/#{zone_id}/dns_records",
                body: Records.cloudflare_body(rec), why: "create #{rec}")
    end

    def update_record(zone_id, rec)
      Write.new(api: :cloudflare, verb: :patch, path: "/zones/#{zone_id}/dns_records/#{rec.id}",
                body: { "proxied" => rec.proxied }, why: "set #{rec}")
    end

    def replace_record(zone_id, rec, content)
      Write.new(api: :cloudflare, verb: :patch, path: "/zones/#{zone_id}/dns_records/#{rec.id}",
                body: { "content" => content }, why: "replace #{rec} with #{content.inspect}")
    end

    def delete_record(zone_id, rec, why: "conflicts with an app record")
      Write.new(api: :cloudflare, verb: :delete, path: "/zones/#{zone_id}/dns_records/#{rec.id}",
                why: "delete #{rec}: #{why}")
    end

    def set_ssl_strict(zone_id)
      Write.new(api: :cloudflare, verb: :patch, path: "/zones/#{zone_id}/settings/ssl",
                body: { "value" => "strict" }, why: "SSL Full (strict): the edge talks to Heroku only over a valid certificate")
    end

    # The www -> bare rule, upserted by its ref among the phase's other rules (a
    # PUT on the entrypoint replaces the whole list, so the rest are carried).
    def redirect_rule(domain, enabled:)
      {
        "ref" => REDIRECT_REF,
        "description" => "www to bare (bin/domain-cutover)",
        "expression" => %((http.host eq "www.#{domain}")),
        "action" => "redirect",
        "action_parameters" => {
          "from_value" => {
            "status_code" => 301,
            "preserve_query_string" => true,
            "target_url" => { "expression" => %(concat("https://#{domain}", http.request.uri.path)) }
          }
        },
        "enabled" => enabled
      }
    end

    def put_redirect(zone_id, domain, existing_rules, enabled:)
      ours = redirect_rule(domain, enabled: enabled)
      carried = existing_rules.reject { |r| r["ref"] == REDIRECT_REF }.map do |r|
        r.slice("id", "ref", "description", "expression", "action", "action_parameters", "enabled")
      end
      Write.new(api: :cloudflare, verb: :put, path: "/zones/#{zone_id}/rulesets/phases/#{REDIRECT_PHASE}/entrypoint",
                body: { "rules" => carried + [ours] },
                why: "www -> bare 301 #{enabled ? 'ENABLED' : 'written DISABLED (finalize enables it)'}")
    end

    def activation_check(zone_id)
      Write.new(api: :cloudflare, verb: :put, path: "/zones/#{zone_id}/activation_check",
                why: "ask Cloudflare to re-check the registry's nameservers now")
    end

    def perform(write)
      request(write.verb, write.path, write.body)["result"]
    end

    private

    def get(path) = request(:get, path)["result"]

    def request(verb, path, body = nil, allow: [])
      res = @transport.call(verb, "#{BASE}#{path}",
                            headers: { "Authorization" => "Bearer #{@token}", "content-type" => "application/json" },
                            body: body && JSON.generate(body))
      return {} if allow.include?(res.status)

      json = res.json
      return json if res.ok? && json["success"] != false

      errors = Array(json["errors"]).map { |e| "#{e['code']} #{e['message']}" }.join("; ")
      raise Abort, DomainCutover.redact("Cloudflare #{verb.upcase} #{path}: HTTP #{res.status} #{errors}", [@token])
    end
  end
end
