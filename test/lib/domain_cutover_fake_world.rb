# frozen_string_literal: true

# DomainCutoverFakeWorld — an in-memory internet for bin/lib/domain_cutover: the
# two DoH resolvers, RDAP, Cloudflare's API and Heroku's API, behind the one
# Transport#call seam the library uses. Nothing here opens a socket.
#
# The world is stateful the way the real one is: a zone created over the API
# starts `pending` and EMPTY (Cloudflare's import can come back empty), the
# resolvers answer from the OLD zone until `delegate_to_cloudflare!`, a PUT on
# activation_check activates the zone only once the registry shows its
# nameservers, Heroku's config-vars read lags one read behind a PATCH, and ACM
# issues only after a refresh made while the bare domain resolves.

require "json"
require "uri"
require_relative "../../bin/lib/domain_cutover"

class DomainCutoverFakeWorld
  CF_NS = %w[ada.ns.cloudflare.com bob.ns.cloudflare.com].freeze
  HEROKU_TARGET = "shiny-owl-abc123.herokudns.com"
  TOKEN = "cf-secret-token-0123456789"
  HEROKU_KEY = "HRKU-secret-key-0123456789"

  attr_accessor :registrar, :registry_ns, :ds, :servfail, :old_zone, :zones, :config, :domains,
                :rules, :ssl, :delegated
  attr_reader :log

  def initialize(domain: "example.com", app: "example-app")
    @domain = domain
    @app = app
    @log = []
    @registrar = "Squarespace Domains II LLC"
    @registry_ns = %w[nsa1.squarespacedns.com nsa2.squarespacedns.com]
    @ds = true
    @servfail = false
    @delegated = false
    @old_zone = {
      domain => { "A" => %w[198.185.159.144 198.185.159.145], "MX" => ["1 smtp.google.com."],
                  "TXT" => ["google-site-verification=abc", "v=spf1 include:_spf.google.com ~all"] },
      "www.#{domain}" => { "CNAME" => ["ext-sq.squarespace.com."] },
      "google._domainkey.#{domain}" => { "TXT" => ["v=DKIM1; k=rsa; p=MIIBIjAN"] },
      "_dmarc.#{domain}" => { "TXT" => ["v=DMARC1; p=none; rua=mailto:team@#{domain}"] },
      "in.#{domain}" => { "MX" => ["10 inbound-smtp.us-east-1.amazonaws.com."] }
    }
    @zones = {}       # id => { "zone" => {...}, "records" => [rows] }
    @rules = {}       # zone id => [rules] (absent: 404)
    @ssl = {}
    @domains = {}     # hostname => row
    @config = { "APP_HOST" => "www.#{domain}" }
    @config_lag = nil
    @next_id = 0
  end

  # ── what the tests flip ───────────────────────────────────────────────────
  def registry_on_cloudflare!(zone_ns = zone&.dig("zone", "name_servers"))
    @registry_ns = zone_ns
    @ds = false
  end

  def delegate_to_cloudflare! = @delegated = true

  def zone = @zones.values.first
  def zone_records = zone ? zone["records"] : []
  def writes = @log.reject { |verb, _| verb == :get }
  def redirect_rule = Array(@rules[zone&.dig("zone", "id")]).find { |r| r["ref"] == DomainCutover::Cloudflare::REDIRECT_REF }

  # ── Transport ─────────────────────────────────────────────────────────────
  def call(verb, url, headers: {}, body: nil)
    @log << [verb, url]
    uri = URI(url)
    payload = body && JSON.parse(body)
    case uri.host
    when "dns.google", "cloudflare-dns.com" then doh(uri)
    when "rdap.org" then rdap
    when "api.cloudflare.com"
      raise "Cloudflare called without the token" unless headers["Authorization"] == "Bearer #{TOKEN}"

      cloudflare(verb, uri, payload)
    when "api.heroku.com"
      raise "Heroku called without the key" unless headers["Authorization"] == "Bearer #{HEROKU_KEY}"

      heroku(verb, uri, payload)
    else raise "unexpected host #{uri.host}"
    end
  end

  private

  def ok(obj, status = 200) = DomainCutover::Response.new(status: status, body: JSON.generate(obj))

  TYPE_CODES = DomainCutover::Doh::TYPES

  def doh(uri)
    q = URI.decode_www_form(uri.query).to_h
    name = q["name"].downcase
    type = q["type"]
    return ok({ "Status" => 2 }) if @servfail && q["cd"] != "1"

    if type == "DS"
      data = @ds && name == @domain ? ["12345 13 2 ABCDEF"] : []
    elsif type == "NS" && name == @domain
      data = (@delegated ? CF_NS : %w[nsa1.squarespacedns.com nsa2.squarespacedns.com]).map { |n| "#{n}." }
    else
      data = @delegated ? from_zone(name, type) : Array(@old_zone.dig(name, type))
    end
    data = data.map { |d| type == "TXT" && uri.host == "cloudflare-dns.com" ? %("#{d}") : d }
    answers = data.map { |d| { "name" => "#{name}.", "type" => TYPE_CODES.fetch(type), "TTL" => 300, "data" => d } }
    ok({ "Status" => 0, "Answer" => answers })
  end

  # What Cloudflare's nameservers answer: the apex CNAME flattened, www proxied.
  def from_zone(name, type)
    rows = zone_records.select { |r| r["name"] == name }
    if type == "A" && rows.any? { |r| r["type"] == "CNAME" }
      return rows.find { |r| r["type"] == "CNAME" }["proxied"] ? ["104.16.0.1"] : ["203.0.113.10"]
    end
    return [] if type == "CNAME" && (name == @domain || rows.any? { |r| r["proxied"] })

    rows.select { |r| r["type"] == type }.map do |r|
      case type
      when "MX" then "#{r['priority']} #{r['content']}."
      when "CNAME" then "#{r['content']}."
      else r["content"]
      end
    end
  end

  def rdap
    ok({
         "ldhName" => @domain.upcase,
         "entities" => [{ "roles" => ["registrar"],
                          "vcardArray" => ["vcard", [["version", {}, "text", "4.0"], ["fn", {}, "text", @registrar]]] }],
         "nameservers" => @registry_ns.map { |n| { "ldhName" => n.upcase } },
         "secureDNS" => { "delegationSigned" => @ds }
       })
  end

  def cf_ok(result) = ok({ "success" => true, "errors" => [], "result" => result, "result_info" => { "total_pages" => 1 } })

  def cloudflare(verb, uri, payload)
    path = uri.path.delete_prefix("/client/v4")
    case [verb, path]
    in [:get, "/zones"]
      want = URI.decode_www_form(uri.query.to_s).to_h["name"]
      cf_ok(@zones.values.map { |z| z["zone"] }.select { |z| z["name"] == want })
    in [:post, "/zones"]
      id = "zone#{@next_id += 1}"
      @zones[id] = { "zone" => { "id" => id, "name" => payload["name"], "status" => "pending", "name_servers" => CF_NS },
                     "records" => [] }
      cf_ok(@zones[id]["zone"])
    in [:get, %r{\A/zones/([^/]+)\z}]
      cf_ok(@zones.fetch(Regexp.last_match(1))["zone"])
    in [:get, %r{\A/zones/([^/]+)/dns_records\z}]
      cf_ok(@zones.fetch(Regexp.last_match(1))["records"])
    in [:post, %r{\A/zones/([^/]+)/dns_records\z}]
      row = payload.merge("id" => "rec#{@next_id += 1}")
      row["content"] = "#{row['data']['flags']} #{row['data']['tag']} \"#{row['data']['value']}\"" if row["data"]
      @zones.fetch(Regexp.last_match(1))["records"] << row
      cf_ok(row)
    in [:patch, %r{\A/zones/([^/]+)/dns_records/([^/]+)\z}]
      row = @zones.fetch(Regexp.last_match(1))["records"].find { |r| r["id"] == Regexp.last_match(2) }
      row.merge!(payload)
      cf_ok(row)
    in [:delete, %r{\A/zones/([^/]+)/dns_records/([^/]+)\z}]
      rid = Regexp.last_match(2)
      @zones.fetch(Regexp.last_match(1))["records"].reject! { |r| r["id"] == rid }
      cf_ok({ "id" => rid })
    in [:patch, %r{\A/zones/([^/]+)/settings/ssl\z}]
      @ssl[Regexp.last_match(1)] = payload["value"]
      cf_ok({ "id" => "ssl", "value" => payload["value"] })
    in [:get, %r{\A/zones/([^/]+)/settings/ssl\z}]
      cf_ok({ "id" => "ssl", "value" => @ssl.fetch(Regexp.last_match(1), "full") })
    in [:get, %r{\A/zones/([^/]+)/rulesets/phases/http_request_dynamic_redirect/entrypoint\z}]
      rules = @rules[Regexp.last_match(1)]
      rules ? cf_ok({ "rules" => rules }) : ok({ "success" => false, "errors" => [] }, 404)
    in [:put, %r{\A/zones/([^/]+)/rulesets/phases/http_request_dynamic_redirect/entrypoint\z}]
      @rules[Regexp.last_match(1)] = payload["rules"].map { |r| { "id" => "rule-#{r['ref']}" }.merge(r) }
      cf_ok({ "rules" => @rules[Regexp.last_match(1)] })
    in [:put, %r{\A/zones/([^/]+)/activation_check\z}]
      z = @zones.fetch(Regexp.last_match(1))["zone"]
      z["status"] = "active" if @registry_ns.sort == z["name_servers"].sort
      cf_ok({ "id" => z["id"] })
    end
  end

  def heroku(verb, uri, payload)
    path = uri.path
    case [verb, path]
    in [:get, %r{\A/apps/[^/]+/domains/([^/]+)\z}]
      row = @domains[Regexp.last_match(1)]
      row ? ok(row) : ok({ "id" => "not_found", "message" => "Couldn't find that domain." }, 404)
    in [:post, %r{\A/apps/[^/]+/domains\z}]
      @domains[payload["hostname"]] = { "hostname" => payload["hostname"], "cname" => HEROKU_TARGET,
                                        "acm_status" => "pending" }
      ok(@domains[payload["hostname"]], 201)
    in [:get, %r{\A/apps/[^/]+/config-vars\z}]
      if @config_lag
        stale = @config_lag
        @config_lag = nil
        return ok(stale)
      end
      ok(@config)
    in [:patch, %r{\A/apps/[^/]+/config-vars\z}]
      @config_lag = @config.dup # the next read still shows the old values
      @config = @config.merge(payload)
      ok(@config)
    in [:patch, %r{\A/apps/[^/]+/acm\z}]
      @domains[@domain]["acm_status"] = "cert issued" if @delegated && @domains[@domain]
      ok({ "acm" => true })
    end
  end
end
