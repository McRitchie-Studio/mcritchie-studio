require "net/http"
require "openssl"
require "uri"
require "json"
require "base64"

module GoogleConnect
  # OAuth 2.0 for the Google connection (GoogleConnection): the `sign_in`
  # method of config/integrations.yml, dogfooded on the hub's own admin page
  # and /integrations cards first.
  #
  #   1. /admin/google/connect?ability=gmail redirects to Google's sign-in,
  #      asking for who the account is and that ability's one read scope, with
  #      offline access (a refresh token) and include_granted_scopes (Google
  #      adds it to what the account already granted: incremental consent).
  #      ?ability=all (Connect Google) asks for every ability's scope at once;
  #      Google shows a checkbox per scope, so the person may untick some.
  #   2. Google redirects to /admin/google_calendar/callback with ?code= (the
  #      path the OAuth client registered first, kept so no console change is owed)
  #   3. The callback exchanges the code and stores GoogleConnection
  #
  # ITS OWN OAUTH CLIENT, never the hub's sign-in client (GOOGLE_CLIENT_ID):
  # a Google API scope on the sign-in client would tie this grant to the login's
  # secret, so rotating one would break the other.
  #
  # WHAT IT ASKS FOR: who the account is (openid, email) and one scope per
  # ability (GoogleConnection::ABILITIES): read-only calendar events and Gmail,
  # and Drive's drive.file, which reaches only the files the person picks (or
  # the app creates). The hub only reads; no reader holds a write path.
  #
  # Env vars (names only; values live in 1Password and Heroku config):
  #   GOOGLE_CONNECT_CLIENT_ID      the connections OAuth client's id
  #   GOOGLE_CONNECT_CLIENT_SECRET  its secret
  class OAuthClient
    AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth".freeze
    TOKEN_URL = "https://oauth2.googleapis.com/token".freeze
    REVOKE_URL = "https://oauth2.googleapis.com/revoke".freeze
    ENV_NAMES = %w[GOOGLE_CONNECT_CLIENT_ID GOOGLE_CONNECT_CLIENT_SECRET].freeze

    # What reaching Google can raise below HTTP: TLS, refused, timed out, DNS.
    NETWORK_ERRORS = [ OpenSSL::SSL::SSLError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout ].freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # Google refused the refresh token: revoked, unused six months, or replaced.
    class Revoked < Error; end

    class << self
      # Stand-in for Google's HTTP: (method, url, form) -> [status, body].
      # nil means Google itself. Set in tests only.
      attr_accessor :http

      # Stand-in for Google's side of the sign-in (authorize_url and
      # exchange_code), for the e2e lane and a local demo. Never production.
      attr_accessor :sign_in_stand_in

      def configured? = ENV_NAMES.all? { |name| ENV[name].present? }

      # The OAuth client's public id, or nil when unset. Not a secret: Google
      # puts it in every authorize URL. A Workspace admin pastes it into the
      # Admin console to mark the app Trusted (modals/_gmail_admin).
      def client_id = ENV["GOOGLE_CONNECT_CLIENT_ID"].presence

      # The scopes a sign-in for `abilities` asks for: identity plus each one's read.
      def scopes_for(abilities) = GoogleConnection::IDENTITY_SCOPES + Array(abilities).map { GoogleConnection.scope_for(_1) }

      def authorize_url(redirect_uri:, state:, abilities:)
        return sign_in_stand_in.authorize_url(redirect_uri:, state:, scopes: scopes_for(abilities)) if sign_in_stand_in

        ensure_configured!
        params = { client_id: ENV.fetch("GOOGLE_CONNECT_CLIENT_ID"), redirect_uri:, response_type: "code",
                   scope: scopes_for(abilities).join(" "), access_type: "offline", prompt: "consent",
                   include_granted_scopes: "true", state: }
        "#{AUTH_URL}?#{URI.encode_www_form(params)}"
      end

      # The token endpoint's JSON for a sign-in's code: access_token,
      # refresh_token, scope and id_token.
      def exchange_code(code:, redirect_uri:)
        return sign_in_stand_in.exchange_code(code:, redirect_uri:) if sign_in_stand_in

        ensure_configured!
        post(TOKEN_URL, client_id: ENV.fetch("GOOGLE_CONNECT_CLIENT_ID"), client_secret: ENV.fetch("GOOGLE_CONNECT_CLIENT_SECRET"),
                        code:, grant_type: "authorization_code", redirect_uri:)
      end

      # A short-lived access token for the connection. Raises Revoked when
      # Google no longer honours its refresh token.
      def access_token(connection)
        return sign_in_stand_in.access_token(connection) if sign_in_stand_in

        ensure_configured!
        post(TOKEN_URL, client_id: ENV.fetch("GOOGLE_CONNECT_CLIENT_ID"), client_secret: ENV.fetch("GOOGLE_CONNECT_CLIENT_SECRET"),
                        refresh_token: connection.refresh_token, grant_type: "refresh_token").fetch("access_token")
      end

      # Asks Google to drop the grant. Returns whether Google said it did.
      # Never raises: a TLS or network failure reaching Google is logged (its
      # class only) and answers false, so a disconnect still deletes the row.
      def revoke(connection)
        return sign_in_stand_in.revoke(connection) if sign_in_stand_in

        status, = call(:post, REVOKE_URL, token: connection.refresh_token)
        status == 200
      rescue Error, ActiveRecord::Encryption::Errors::Base, *NETWORK_ERRORS => e
        Rails.logger.warn("[google_connect] revoke failed: #{e.class}")
        false
      end

      # The account an exchange signed in, from its id_token. The token came
      # straight from Google's token endpoint over TLS, so its claims are read
      # without a signature check (OpenID Connect Core 3.1.3.7).
      def email_from(grant)
        payload = grant["id_token"].to_s.split(".")[1].to_s
        JSON.parse(Base64.urlsafe_decode64(payload + ("=" * (-payload.size % 4))))["email"].to_s.presence
      rescue ArgumentError, JSON::ParserError
        nil
      end

      private

      def ensure_configured!
        raise NotConfigured, "#{ENV_NAMES.join(' and ')} are not set on this server" unless configured?
      end

      def post(url, form)
        status, body = call(:post, url, form)
        json = JSON.parse(body.to_s) rescue {}
        return json if status == 200

        raise Revoked, "Google no longer accepts this connection (#{json['error']}); sign in again" if json["error"] == "invalid_grant"

        raise Error, "Google answered #{status}: #{json['error_description'] || json['error'] || 'no detail'}"
      end

      def call(method, url, form)
        return http.call(method, url, form) if http

        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(form)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
        [ response.code.to_i, response.body ]
      rescue *NETWORK_ERRORS => e
        raise Error, "Google could not be reached: #{e.class}"
      end
    end
  end
end
