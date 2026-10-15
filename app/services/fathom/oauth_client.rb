require "net/http"
require "openssl"
require "uri"
require "json"

module Fathom
  # OAuth 2.0 for the Fathom connection (FathomConnection): the `sign_in`
  # method of config/integrations.yml, on the hub's own /admin/fathom page and
  # the /integrations Fathom card first.
  #
  #   1. /admin/fathom/connect redirects to Fathom's sign-in, asking for its one
  #      scope (public_api: read the account's meetings).
  #   2. Fathom redirects to /admin/fathom/callback with ?code= (the redirect
  #      registered on both Fathom OAuth apps, production and development)
  #   3. The callback exchanges the code and stores FathomConnection
  #
  # SINGLE-USE REFRESH TOKENS. Each refresh answers a new refresh token and
  # spends the old one, so .access_token refreshes only under the row's lock
  # and stores the new token before handing back the access token. A refresh
  # per read is the whole cache: the access token lives only as long as the
  # Reader that asked for it (one page load), and no token outlives a request.
  #
  # NO REVOKE. Fathom documents no revoke endpoint, so Disconnect deletes the
  # stored token here and says so; removing the app's access is done in Fathom.
  #
  # Env vars (names only; values live in 1Password and Heroku config):
  #   FATHOM_CLIENT_ID      the Fathom OAuth app's id
  #   FATHOM_CLIENT_SECRET  its secret
  class OAuthClient
    AUTH_URL = "https://fathom.video/external/v1/oauth2/authorize".freeze
    TOKEN_URL = "https://fathom.video/external/v1/oauth2/token".freeze
    SCOPE = "public_api".freeze
    ENV_NAMES = %w[FATHOM_CLIENT_ID FATHOM_CLIENT_SECRET].freeze

    # What reaching Fathom can raise below HTTP: TLS, refused, timed out, DNS.
    NETWORK_ERRORS = [ OpenSSL::SSL::SSLError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout ].freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # Fathom refused the refresh token: revoked, expired, or already spent.
    class Revoked < Error; end

    class << self
      # Stand-in for Fathom's token endpoint: (url, form) -> [status, body].
      # nil means Fathom itself. Set in tests, the e2e lane and a local demo only.
      attr_accessor :http

      # Stand-in for Fathom's sign-in page (authorize_url only), for the e2e
      # lane and a local demo. Never production. The code exchange and the
      # refresh still run through .http, so the rotation is the real one.
      attr_accessor :sign_in_stand_in

      def configured? = ENV_NAMES.all? { |name| ENV[name].present? }

      # Can a Connect start on this server: the OAuth app is set, or the stand-in is.
      def connectable? = configured? || !sign_in_stand_in.nil?

      def authorize_url(redirect_uri:, state:)
        return sign_in_stand_in.authorize_url(redirect_uri:, state:) if sign_in_stand_in

        ensure_configured!
        params = { client_id: ENV.fetch("FATHOM_CLIENT_ID"), redirect_uri:, scope: SCOPE, state:, response_type: "code" }
        "#{AUTH_URL}?#{URI.encode_www_form(params)}"
      end

      # The token endpoint's JSON for a sign-in's code: access_token, refresh_token, expires_in.
      def exchange_code(code:, redirect_uri:)
        post(grant_type: "authorization_code", code:, redirect_uri:)
      end

      # A short-lived access token for the connection. Refreshes under the
      # row's lock and stores the new single-use refresh token (rotate!) before
      # returning, so a racing refresh waits and then spends the NEW token.
      # Raises Revoked when Fathom no longer honours the stored token.
      def access_token(connection, now: Time.current)
        grant = connection.with_lock do
          answer = post(grant_type: "refresh_token", refresh_token: connection.refresh_token)
          raise Error, "Fathom answered a refresh with no new refresh token; connect again" if answer["refresh_token"].blank?

          connection.rotate!(answer["refresh_token"], now:)
          answer
        end
        # After the lock commits: a raise inside it would roll back the new token Fathom already rotated.
        grant.fetch("access_token") { raise Error, "Fathom answered a refresh with no access token" }
      end

      private

      def ensure_configured!
        raise NotConfigured, "#{ENV_NAMES.join(' and ')} are not set on this server" unless configured? || http
      end

      def post(form)
        ensure_configured!
        form = form.merge(client_id: ENV["FATHOM_CLIENT_ID"].to_s, client_secret: ENV["FATHOM_CLIENT_SECRET"].to_s)
        status, body = call(TOKEN_URL, form)
        json = JSON.parse(body.to_s) rescue {}
        json = {} unless json.is_a?(Hash)
        return json if status == 200

        raise Revoked, "Fathom no longer accepts this connection (#{json['error']}); connect again" if json["error"] == "invalid_grant"

        raise Error, "Fathom answered #{status}: #{json['error_description'] || json['error'] || 'no detail'}"
      end

      def call(url, form)
        return http.call(url, form) if http

        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(form)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
        [ response.code.to_i, response.body ]
      rescue *NETWORK_ERRORS => e
        raise Error, "Fathom could not be reached: #{e.class}"
      end
    end
  end
end
