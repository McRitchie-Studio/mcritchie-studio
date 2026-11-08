require "net/http"
require "openssl"
require "uri"
require "json"
require "base64"

module Quickbooks
  # OAuth 2.0 for the QuickBooks Online connection (QuickbooksConnection): the
  # `sign_in` method of config/integrations.yml, on the hub's own
  # /admin/quickbooks page and the /integrations QuickBooks card.
  #
  #   1. /admin/quickbooks/connect redirects to Intuit's sign-in, asking for
  #      com.intuit.quickbooks.accounting (the only scope that reads a company's
  #      books; the hub uses it read only).
  #   2. Intuit redirects to /admin/quickbooks/callback with ?code=, ?state= and
  #      ?realmId= (the company the person picked). The callback path is the
  #      redirect URI registered on the Intuit app: keep it exactly.
  #   3. The callback exchanges the code and stores QuickbooksConnection.
  #
  # The endpoints are Intuit's discovery document's
  # (developer.api.intuit.com/.well-known/openid_configuration, the same for
  # sandbox and production). The token and revoke calls authenticate with HTTP
  # Basic (client id and secret), as Intuit's own OAuth clients do.
  #
  # ROTATING REFRESH TOKENS. Access tokens last an hour. A refresh may answer a
  # new refresh token, and Intuit says to keep the latest it gave, so
  # .access_token refreshes only under the row's lock and stores the answered
  # token before handing back the access token. A refresh per Reader is the
  # whole cache: no access token outlives a request.
  #
  # REVOKE. Intuit has a revoke endpoint; Disconnect calls it with the refresh
  # token (which ends the whole grant), then deletes the row either way.
  #
  # Env vars (names only; values live in 1Password and Heroku config):
  #   INTUIT_CLIENT_ID      the Intuit app's client id
  #   INTUIT_CLIENT_SECRET  its secret
  #   INTUIT_ENVIRONMENT    sandbox (the default) or production: which Intuit
  #                         keys these are, and so which API host a new
  #                         connection reads
  class OAuthClient
    AUTH_URL = "https://appcenter.intuit.com/connect/oauth2".freeze
    TOKEN_URL = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer".freeze
    REVOKE_URL = "https://developer.api.intuit.com/v2/oauth2/tokens/revoke".freeze
    SCOPE = "com.intuit.quickbooks.accounting".freeze
    ENV_NAMES = %w[INTUIT_CLIENT_ID INTUIT_CLIENT_SECRET].freeze
    ENVIRONMENT_ENV = "INTUIT_ENVIRONMENT".freeze

    # What reaching Intuit can raise below HTTP: TLS, refused, timed out, DNS.
    NETWORK_ERRORS = [ OpenSSL::SSL::SSLError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout ].freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # Intuit refused the refresh token: revoked, expired, or superseded.
    class Revoked < Error; end

    class << self
      # Stand-in for Intuit's token and revoke endpoints:
      # (url, form, headers) -> [status, body]. nil means Intuit itself. Set in
      # tests, the e2e lane and a local demo only.
      attr_accessor :http

      # Stand-in for Intuit's sign-in page (authorize_url only), for the e2e
      # lane and a local demo. Never production. The code exchange and the
      # refresh still run through .http, so the rotation is the real one.
      attr_accessor :sign_in_stand_in

      def configured? = ENV_NAMES.all? { |name| ENV[name].present? }

      # Can a Connect start on this server: the Intuit app is set, or the stand-in is.
      def connectable? = configured? || !sign_in_stand_in.nil?

      # The Intuit environment a new connection lands in. Anything but
      # "production" is the sandbox: a typo never points sandbox keys at live books.
      def environment = ENV[ENVIRONMENT_ENV].to_s.strip.downcase == "production" ? "production" : "sandbox"

      def authorize_url(redirect_uri:, state:)
        return sign_in_stand_in.authorize_url(redirect_uri:, state:) if sign_in_stand_in

        ensure_configured!
        params = { client_id: ENV.fetch("INTUIT_CLIENT_ID"), redirect_uri:, scope: SCOPE, state:, response_type: "code" }
        "#{AUTH_URL}?#{URI.encode_www_form(params)}"
      end

      # The token endpoint's JSON for a sign-in's code: access_token,
      # refresh_token, expires_in, x_refresh_token_expires_in.
      def exchange_code(code:, redirect_uri:)
        post_token(grant_type: "authorization_code", code:, redirect_uri:)
      end

      # A short-lived access token for the connection. Refreshes under the
      # row's lock and stores the answered refresh token (rotate!) before
      # returning, so a racing refresh waits and then spends the NEWEST token.
      # Raises Revoked when Intuit no longer honours the stored token.
      def access_token(connection, now: Time.current)
        grant = connection.with_lock do
          answer = post_token(grant_type: "refresh_token", refresh_token: connection.refresh_token)
          raise Error, "Intuit answered a refresh with no refresh token; connect again" if answer["refresh_token"].blank?

          connection.rotate!(answer, now:)
          answer
        end
        # After the lock commits: a raise inside it would roll back the token Intuit already rotated.
        grant.fetch("access_token") { raise Error, "Intuit answered a refresh with no access token" }
      end

      # Revokes the connection's grant at Intuit. True when Intuit took it;
      # raises Error with Intuit's answer otherwise.
      def revoke(connection)
        ensure_configured!
        status, body = call(REVOKE_URL, { token: connection.refresh_token }, headers(json: true))
        return true if status == 200

        raise Error, "Intuit answered #{status}: #{detail(parse(body))}"
      end

      private

      def ensure_configured!
        raise NotConfigured, "#{ENV_NAMES.join(' and ')} are not set on this server" unless configured? || http
      end

      def headers(json: false)
        credentials = Base64.strict_encode64("#{ENV['INTUIT_CLIENT_ID']}:#{ENV['INTUIT_CLIENT_SECRET']}")
        { "Authorization" => "Basic #{credentials}", "Accept" => "application/json",
          "Content-Type" => json ? "application/json" : "application/x-www-form-urlencoded" }
      end

      def post_token(form)
        ensure_configured!
        status, body = call(TOKEN_URL, form, headers)
        json = parse(body)
        return json if status == 200

        raise Revoked, "Intuit no longer accepts this connection (#{json['error']}); connect again" if json["error"] == "invalid_grant"

        raise Error, "Intuit answered #{status}: #{detail(json)}"
      end

      def parse(body)
        json = JSON.parse(body.to_s) rescue {}
        json.is_a?(Hash) ? json : {}
      end

      def detail(json) = json["error_description"] || json["error"] || "no detail"

      def call(url, form, headers)
        return http.call(url, form, headers) if http

        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = headers["Content-Type"] == "application/json" ? JSON.generate(form) : URI.encode_www_form(form)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
        [ response.code.to_i, response.body ]
      rescue *NETWORK_ERRORS => e
        raise Error, "Intuit could not be reached: #{e.class}"
      end
    end
  end
end
