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
  # Cloudflare ANSWERED, with an HTTP error. `status` and the raw `errors` let a
  # caller tell a definite refusal (4xx) from an ambiguous one (5xx).
  class HttpError < Abort
    attr_reader :status, :errors

    def initialize(message, status:, errors: [])
      super(message)
      @status = status
      @errors = errors
    end

    def rejected? = status.between?(400, 499)
  end

  # The request was sent (or may have been) and NO answer came back: timeout,
  # reset, TLS failure. For the purchase POST that means money MAY have moved.
  class NoAnswer < Abort; end

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
      request(:get, status_path(domain))["result"] || {}
    end

    # Has Cloudflare EVER started a registration for this domain? Asked before
    # every purchase, so a re-run can never buy twice while a first workflow is
    # still in flight. Answers nil ONLY on the documented not-found: a 4xx whose
    # errors carry code 10000 "No workflow found for <domain>" (the 4XX example on
    # https://developers.cloudflare.com/api/resources/registrar/subresources/registration_status/methods/get;
    # the page names no HTTP status, so none is assumed). A 2xx answers the
    # workflow. Anything else (a 5xx, an auth error, another 4xx, no answer)
    # raises: fail closed, because "could not tell" must never read as "never bought".
    def existing_workflow(domain)
      request(:get, status_path(domain))["result"] || {}
    rescue HttpError => e
      return nil if e.status.between?(400, 499) && not_found?(e.errors, domain)

      raise
    end

    def self.not_found_message?(message, domain)
      message.to_s.strip.casecmp?("No workflow found for #{domain}")
    end

    # The dashboard step that clears a refusal, or nil when the message is not a
    # known prerequisite.
    def self.prerequisite_for(message)
      PREREQUISITES.find { |pattern, _| message.match?(pattern) }&.last
    end

    private

    def status_path(domain) = "/registrar/registrations/#{URI.encode_www_form_component(domain)}/registration-status"

    def not_found?(errors, domain)
      errors.any? { |e| e["code"].to_i == 10_000 && self.class.not_found_message?(e["message"], domain) }
    end

    def request(verb, path, body = nil)
      res = begin
        @transport.call(verb, "#{@base}/accounts/#{@account_id}#{path}",
                        headers: { "Authorization" => "Bearer #{@token}", "content-type" => "application/json" },
                        body: body && JSON.generate(body))
      rescue StandardError => e
        # The request may have reached Cloudflare: a read timeout, a reset or an
        # empty reply (EOFError, which the shared Transport does not translate)
        # after the bytes went out says nothing about what Cloudflare did. Every
        # failure to hear an answer is NoAnswer, never an ordinary refusal.
        raise NoAnswer, DomainRegister.redact("Cloudflare #{verb.upcase} #{path}: no answer (#{e.message})",
                                              [@token, @account_id])
      end
      json = res.json
      return json if res.ok? && json["success"] != false

      errors = Array(json["errors"]).map { |e| "#{e['code']} #{e['message']}".strip }.join("; ")
      errors = "(no error body)" if errors.empty?
      hint = self.class.prerequisite_for(errors)
      message = "Cloudflare #{verb.upcase} #{path}: HTTP #{res.status} #{errors}"
      message += "\n  -> #{hint}" if hint
      raise HttpError.new(DomainRegister.redact(message, [@token, @account_id]),
                          status: res.status, errors: Array(json["errors"]))
    end
  end
end
