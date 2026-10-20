# frozen_string_literal: true

require "json"
require "uri"

module DomainRegister
  # Cloudflare's Registrar API (beta since 2026-04-15), with the Registrar-only
  # token. Docs: https://developers.cloudflare.com/registrar/registrar-api/
  #
  #   POST /accounts/{id}/registrar/domain-check            { "domains": [...] }, at most 20
  #   POST /accounts/{id}/registrar/registrations           { "domain_name", "auto_renew", "privacy_mode", "years" }
  #   GET  /accounts/{id}/registrar/registrations/{d}/registration-status
  #
  # A registration answers 201 (finished inside Cloudflare's ten-second window)
  # or 202 (still running: poll registration-status). Both carry a workflow
  # status: { state, completed, context, error, links }.
  #
  # The registration POST is the one call that spends money. It is reached only
  # through Runner#register, after every refusal has passed.
  class Registrar
    BASE = "https://api.cloudflare.com/client/v4"
    CHECK_LIMIT = 20

    # Cloudflare documents no codes for the three dashboard prerequisites (its
    # validation errors are all code 10000), so each is recognized by its
    # message and answered with the dashboard step that clears it.
    PREREQUISITES = [
      [/authentication error|unauthori[sz]ed|invalid api token|permission/i,
       "the token cannot use the Registrar API. Use the admin-lane item cloudflare.registrar, field api-token " \
       "(permission Account > Registrar > Edit), never the DNS token cloudflare.studio.provision."],
      [/payment|billing|card|charge/i,
       "no default payment method. Alex: Cloudflare dashboard > Manage Account > Billing > Payment info, " \
       "add a card and make it the default."],
      [/agreement|terms/i,
       "the Domain Registration Agreement is not accepted. Alex: Cloudflare dashboard > Domain Registration > " \
       "Register Domains, accept the agreement once."],
      [/contact|address book|registrant/i,
       "no default registrant contact. Alex: Cloudflare dashboard > Domain Registration > Manage, set the " \
       "default registrant contact (the entity's name, address, phone and email)."],
      [/domain limit|limit reached/i,
       "the account has reached Cloudflare's per-account domain limit; ask Cloudflare to raise it."]
    ].freeze

    # The integration test points the whole CLI at a stub server on loopback.
    # Nothing else may: a typo'd or planted base would hand the token to a
    # stranger, so any non-loopback value refuses before a call is made.
    BASE_ENV = "DOMAIN_REGISTER_API_BASE"
    LOOPBACK = %w[127.0.0.1 localhost].freeze

    def self.base(env = ENV)
      value = env[BASE_ENV].to_s.strip
      return BASE if value.empty?

      host = begin
        URI(value).host
      rescue URI::InvalidURIError
        nil
      end
      raise Abort, "#{BASE_ENV} may point only at loopback (a test stub), not #{host || value}. Nothing ran." unless LOOPBACK.include?(host)

      value.delete_suffix("/")
    end

    def initialize(transport, token:, account_id:, base: self.class.base)
      @transport = transport
      @token = token
      @account_id = account_id
      @base = base
    end

    def check(domains)
      raise ArgumentError, "domain-check takes 1..#{CHECK_LIMIT} domains" unless domains.length.between?(1, CHECK_LIMIT)

      body = request(:post, "/registrar/domain-check", { "domains" => domains })
      Array(body.dig("result", "domains")).map { |row| Quote.from_api(row) }
    end

    # The request body, built separately so --dry-run can print exactly what
    # would be sent.
    def registration_body(domain)
      { "domain_name" => domain, "auto_renew" => true, "privacy_mode" => "redaction", "years" => 1 }
    end

    def register(domain)
      request(:post, "/registrar/registrations", registration_body(domain))["result"] || {}
    end

    def status(domain)
      request(:get, "/registrar/registrations/#{URI.encode_www_form_component(domain)}/registration-status")["result"] || {}
    end

    # The dashboard step that clears a refusal, or nil when the message is not a
    # known prerequisite.
    def self.prerequisite_for(message)
      PREREQUISITES.find { |pattern, _| message.match?(pattern) }&.last
    end

    private

    def request(verb, path, body = nil)
      res = @transport.call(verb, "#{@base}/accounts/#{@account_id}#{path}",
                            headers: { "Authorization" => "Bearer #{@token}", "content-type" => "application/json" },
                            body: body && JSON.generate(body))
      json = res.json
      return json if res.ok? && json["success"] != false

      errors = Array(json["errors"]).map { |e| "#{e['code']} #{e['message']}".strip }.join("; ")
      errors = "(no error body)" if errors.empty?
      hint = self.class.prerequisite_for(errors)
      message = "Cloudflare #{verb.upcase} #{path}: HTTP #{res.status} #{errors}"
      message += "\n  -> #{hint}" if hint
      raise Abort, DomainRegister.redact(message, [@token, @account_id])
    end
  end
end
