require "net/http"
require "openssl"
require "uri"
require "json"

module Egnyte
  # OAuth 2.0 for the Egnyte connection (EgnyteConnection): the `sign_in`
  # method of config/integrations.yml, on the hub's own /admin/egnyte page and
  # the /integrations Egnyte card. The authorization code flow, as Egnyte's
  # authentication docs give it (read 2026-11-06), on the domain's own host:
  #
  #   1. The admin names the domain; /admin/egnyte/connect redirects to
  #      https://<domain>.egnyte.com/puboauth/token?response_type=code, asking
  #      for one scope (Egnyte.filesystem: folders, metadata, upload).
  #   2. Egnyte redirects to /admin/egnyte/callback with ?code= (the redirect
  #      registered on the Egnyte developer key).
  #   3. The callback exchanges the code (a form POST to the same path) and
  #      stores EgnyteConnection.
  #
  # TOKENS. The access token lives 30 days; a refresh answers a new access
  # token and a new refresh token. .access_token hands back the stored token
  # while it is fresh and refreshes only near its expiry (or after a 401, named
  # by `stale:`), under the row's lock, storing the new pair before returning.
  # Egnyte throttles its token endpoint (409 with Retry-After) and asks callers
  # to cache tokens, so a page load costs no refresh most days.
  #
  # REVOKE. POST /pubapi/v1/tokens/revoke with the token and the client secret
  # revokes the token and its refresh token; Disconnect calls it, then deletes
  # the row.
  #
  # Env vars (names only; values live in 1Password and Heroku config):
  #   EGNYTE_CLIENT_ID      the Egnyte developer key (its API key)
  #   EGNYTE_CLIENT_SECRET  its shared secret
  class OAuthClient
    TOKEN_PATH = "/puboauth/token".freeze
    REVOKE_PATH = "/pubapi/v1/tokens/revoke".freeze
    SCOPE = "Egnyte.filesystem".freeze
    ENV_NAMES = %w[EGNYTE_CLIENT_ID EGNYTE_CLIENT_SECRET].freeze

    # What reaching Egnyte can raise below HTTP: TLS, refused, timed out, DNS.
    NETWORK_ERRORS = [ OpenSSL::SSL::SSLError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout ].freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # Egnyte refused the stored tokens: revoked, expired, a password change, or spent.
    class Revoked < Error; end
    # Egnyte is throttling this key or token (409 on the token endpoint, 429 on the API).
    class RateLimited < Error; end

    class << self
      # Stand-in for Egnyte's token and revoke endpoints: (url, form) ->
      # [status, body]. nil means Egnyte itself. Set in tests, the e2e lane
      # and a local demo only.
      attr_accessor :http

      # Stand-in for Egnyte's sign-in page (authorize_url only), for the e2e
      # lane and a local demo. Never production. The code exchange and the
      # refresh still run through .http, so the rotation is the real one.
      attr_accessor :sign_in_stand_in

      def configured? = ENV_NAMES.all? { |name| ENV[name].present? }

      # Can a Connect start on this server: the developer key is set, or the stand-in is.
      def connectable? = configured? || !sign_in_stand_in.nil?

      def base_url(domain) = "https://#{checked(domain)}#{EgnyteConnection::HOST_SUFFIX}"

      def authorize_url(domain:, redirect_uri:, state:)
        return sign_in_stand_in.authorize_url(domain: checked(domain), redirect_uri:, state:) if sign_in_stand_in

        ensure_configured!
        params = { client_id: ENV.fetch("EGNYTE_CLIENT_ID"), redirect_uri:, scope: SCOPE, state:, response_type: "code" }
        "#{base_url(domain)}#{TOKEN_PATH}?#{URI.encode_www_form(params)}"
      end

      # The token endpoint's JSON for a sign-in's code: access_token,
      # refresh_token, expires_in, token_type.
      def exchange_code(domain:, code:, redirect_uri:)
        post(domain, TOKEN_PATH, { grant_type: "authorization_code", code:, redirect_uri:, scope: SCOPE })
      end

      # An access token for the connection. The stored one while it is fresh;
      # otherwise one refresh under the row's lock, storing the new pair
      # (rotate!) before returning, so a racing caller waits and then reads the
      # NEW token. `stale:` is a token the API just refused with a 401: it is
      # refreshed even when not near expiry, unless another caller already
      # replaced it. Raises Revoked when Egnyte no longer honours the tokens.
      def access_token(connection, stale: nil, now: Time.current)
        connection.with_lock do
          current = connection.access_token
          next current if stale.present? && current != stale
          next current if stale.blank? && connection.access_fresh?(now)
          raise Revoked, "Egnyte refused this connection and it holds no refresh token; connect again" if connection.refresh_token.blank?

          answer = post(connection.domain, TOKEN_PATH, { grant_type: "refresh_token", refresh_token: connection.refresh_token })
          raise Error, "Egnyte answered a refresh with no access token" if answer["access_token"].blank?

          connection.rotate!(answer, now:)
          answer["access_token"]
        end
      end

      # Revokes the connection's tokens on Egnyte (the refresh token revokes the
      # pair). True when Egnyte said 200; raises Error otherwise.
      def revoke(connection)
        token = connection.refresh_token.presence || connection.access_token
        post(connection.domain, REVOKE_PATH, { token: }, client_id: false, allow_empty: true)
        true
      end

      private

      def checked(domain)
        EgnyteConnection.normalize_domain(domain) or raise ArgumentError, "not an Egnyte domain"
      end

      def ensure_configured!
        raise NotConfigured, "#{ENV_NAMES.join(' and ')} are not set on this server" unless configured? || http
      end

      # The revoke endpoint takes the secret but not the id.
      def post(domain, path, form, client_id: true, allow_empty: false)
        ensure_configured!
        creds = { client_secret: ENV["EGNYTE_CLIENT_SECRET"].to_s }
        creds = { client_id: ENV["EGNYTE_CLIENT_ID"].to_s, **creds } if client_id
        status, body = call("#{base_url(domain)}#{path}", form.merge(creds))
        json = JSON.parse(body.to_s) rescue {}
        json = {} unless json.is_a?(Hash)
        return json if status == 200 && (allow_empty || json.any?)

        detail = json["error_description"] || json["error"] || json["message"] || json["errorMessage"]
        raise RateLimited, "Egnyte is throttling sign-ins for this key (#{status}); try again in a few minutes" if [ 409, 429 ].include?(status)
        raise Revoked, "Egnyte no longer accepts this connection (#{detail}); connect again" if revoked?(status, json, detail)

        raise Error, "Egnyte answered #{status}: #{detail || 'no detail'}"
      end

      def revoked?(status, json, detail)
        return false unless [ 400, 401, 403 ].include?(status)

        json["error"] == "invalid_grant" || detail.to_s.match?(/invalid refresh token|invalid_grant/i)
      end

      def call(url, form)
        return http.call(url, form) if http

        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(form)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
        [ response.code.to_i, response.body ]
      rescue *NETWORK_ERRORS => e
        raise Error, "Egnyte could not be reached: #{e.class}"
      end
    end
  end
end
