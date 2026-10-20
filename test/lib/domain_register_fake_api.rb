# frozen_string_literal: true

# DomainRegisterFakeApi — Cloudflare's Registrar API and the zone list, in
# memory, behind the one Transport#call seam bin/lib/domain_register uses.
# Nothing here opens a socket. Every call is logged, so a test can prove which
# calls happened and, above all, that the registration POST did NOT.

require "json"
require "uri"
require_relative "../../bin/lib/domain_register"

class DomainRegisterFakeApi
  TOKEN = "cf-registrar-secret-0123456789"
  DNS_TOKEN = "cf-dns-secret-0123456789"
  ACCOUNT = "acct0123456789abcdef"

  attr_accessor :quotes, :register_reply, :statuses, :zones, :register_error, :on_register,
                :existing, :probe_error, :register_raises
  attr_reader :log

  def initialize
    @log = []
    @quotes = {}
    @statuses = []
    @zones = []
    @register_reply = nil
    @register_error = nil
  end

  def quote(name, registrable: true, tier: "standard", reason: nil, price: "10.46", renewal: "10.46", currency: "USD")
    row = { "name" => name, "registrable" => registrable }
    row["tier"] = tier if tier
    row["reason"] = reason if reason
    row["pricing"] = { "currency" => currency, "registration_cost" => price, "renewal_cost" => renewal } if price
    @quotes[name] = row
    self
  end

  def registrations = @log.select { |c| c[:verb] == :post && c[:url].end_with?("/registrar/registrations") }

  # registration-status reads made AFTER the purchase POST: the poll, not the probe.
  def polls
    first = @log.index { |c| c[:verb] == :post && c[:url].end_with?("/registrar/registrations") }
    return [] if first.nil?

    @log[(first + 1)..].select { |c| c[:url].end_with?("/registration-status") }
  end

  # The documented answer for a domain with no workflow (the 4XX example).
  def not_found(domain)
    fail_with(404, 10_000, "No workflow found for #{domain}")
  end

  def call(verb, url, headers: {}, body: nil)
    @log << { verb: verb, url: url, headers: headers, body: body && JSON.parse(body) }
    path = URI(url).path.delete_prefix("/client/v4")

    case [verb, path]
    in [:post, %r{\A/accounts/[^/]+/registrar/domain-check\z}]
      rows = JSON.parse(body)["domains"].filter_map { |d| @quotes[d] }
      ok(200, { "domains" => rows })
    in [:post, %r{\A/accounts/[^/]+/registrar/registrations\z}]
      @on_register&.call
      if @register_raises
        @created = true # the bytes went out; Cloudflare started a workflow nobody heard about
        raise DomainCutover::Abort, "api.cloudflare.com: Net::ReadTimeout"
      end
      return fail_with(*@register_error) if @register_error

      @created = true

      ok(@register_reply&.fetch(:status, 201) || 201, @register_reply&.fetch(:result) || workflow("succeeded"))
    in [:get, %r{\A/accounts/[^/]+/registrar/registrations/([^/]+)/registration-status\z}]
      domain = Regexp.last_match(1)
      return fail_with(*@probe_error) if @probe_error
      unless @created
        return @existing ? ok(200, @existing) : not_found(domain)
      end

      ok(200, @statuses.length > 1 ? @statuses.shift : @statuses.first || workflow("in_progress"))
    in [:get, "/zones"]
      name = URI.decode_www_form(URI(url).query.to_s).to_h["name"]
      ok(200, @zones.select { |z| z["name"] == name })
    else
      DomainCutover::Response.new(status: 404, body: JSON.generate({ "success" => false, "errors" => [{ "code" => 7000, "message" => "No route" }] }))
    end
  end

  def workflow(state, domain: "acmecorp.dev", error: nil, action: nil)
    w = { "state" => state, "completed" => %w[succeeded failed].include?(state),
          "context" => { "domain_name" => domain } }
    if state == "succeeded"
      w["context"]["registration"] = { "domain_name" => domain, "status" => "active", "auto_renew" => true,
                                       "privacy_mode" => "redaction", "expires_at" => "2027-10-19T00:00:00Z" }
    end
    w["context"]["action"] = action if action
    w["error"] = error if error
    w
  end

  private

  def ok(status, result)
    DomainCutover::Response.new(status: status, body: JSON.generate({ "success" => true, "errors" => [], "result" => result }))
  end

  def fail_with(status, code, message)
    DomainCutover::Response.new(status: status,
                                body: JSON.generate({ "success" => false, "errors" => [{ "code" => code, "message" => message }] }))
  end
end
