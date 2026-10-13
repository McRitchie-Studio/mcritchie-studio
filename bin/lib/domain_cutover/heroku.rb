# frozen_string_literal: true

require "json"

module DomainCutover
  # Heroku's Platform API, with the agent lane key (heroku.studio.agents: domains
  # and config vars). Net::HTTP, not the CLI: the key rides in a header, and the
  # CLI's echo of `config:set` showed stale values on 2026-10-13.
  #
  # The config-vars read LAGS a write by a few seconds, so #config_var_settled
  # re-reads until the value shows or the budget runs out; nothing trusts the
  # PATCH response alone.
  class Heroku
    BASE = "https://api.heroku.com"
    ACCEPT = "application/vnd.heroku+json; version=3"
    # ACM's refresh endpoint answers only on this variant (it is what
    # `heroku certs:auto:refresh` sends).
    ACCEPT_ACM = "application/vnd.heroku+json; version=3.cedar-acm"
    ISSUED = "cert issued"

    def initialize(transport, key:, sleeper: ->(s) { sleep s }, settle_tries: 6, settle_seconds: 3)
      @transport = transport
      @key = key
      @sleeper = sleeper
      @settle_tries = settle_tries
      @settle_seconds = settle_seconds
    end

    # ── reads ────────────────────────────────────────────────────────────────
    # The domain row ({hostname, cname, acm_status, ...}) or nil when absent.
    def domain(app, hostname)
      request(:get, "/apps/#{app}/domains/#{hostname}", allow: [404])
    end

    def config_vars(app) = request(:get, "/apps/#{app}/config-vars")

    # Re-read until every key holds its expected value; returns the last read.
    def config_vars_settled(app, expected)
      vars = {}
      @settle_tries.times do |i|
        vars = config_vars(app)
        return vars if expected.all? { |k, v| vars[k] == v }

        @sleeper.call(@settle_seconds) unless i == @settle_tries - 1
      end
      vars
    end

    # ── writes (built, not run) ──────────────────────────────────────────────
    def add_domain(app, hostname)
      Write.new(api: :heroku, verb: :post, path: "/apps/#{app}/domains",
                body: { "hostname" => hostname, "sni_endpoint" => nil },
                why: "add #{hostname} to #{app}; Heroku answers with its herokudns.com target")
    end

    def set_config(app, vars)
      Write.new(api: :heroku, verb: :patch, path: "/apps/#{app}/config-vars", body: vars,
                why: "set #{vars.keys.join(', ')} on #{app}")
    end

    def acm_refresh(app)
      Write.new(api: :heroku, verb: :patch, path: "/apps/#{app}/acm", body: { "acm_refresh" => true },
                why: "re-issue ACM certificates now that the bare domain resolves publicly")
    end

    def perform(write)
      accept = write.path.end_with?("/acm") ? ACCEPT_ACM : ACCEPT
      request(write.verb, write.path, write.body, accept: accept)
    end

    private

    def request(verb, path, body = nil, allow: [], accept: ACCEPT)
      res = @transport.call(verb, "#{BASE}#{path}",
                            headers: { "Authorization" => "Bearer #{@key}", "Accept" => accept,
                                       "content-type" => "application/json" },
                            body: body && JSON.generate(body))
      return nil if allow.include?(res.status)
      return res.json if res.ok?

      message = res.json["message"] || res.body.to_s[0, 200]
      raise Abort, DomainCutover.redact("Heroku #{verb.upcase} #{path}: HTTP #{res.status} #{message}", [@key])
    end
  end
end
