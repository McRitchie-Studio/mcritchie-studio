require "net/http"
require "uri"
require "json"
require "digest"

module Tiktok
  # OAuth 2.0 client for the TikTok Content Posting API.
  #
  # One-time setup flow (the tiktok-draft SOP, "Setup", has the operator's steps):
  #   1. /admin/tiktok/connect redirects to TikTok's sign-in, asking for requested_scopes
  #   2. The operator signs in as the account the drafts should land in
  #   3. TikTok redirects to /admin/tiktok/callback with ?code=... (or ?error=...)
  #   4. The callback exchanges the code and stores the connection itself
  #      (TiktokConnection). No token is shown and nobody copies one
  #
  # Per-post flow:
  #   access_token    exchanges the refresh token for a short-lived token (cached 50 min)
  #   granted_scopes  the scope TikTok names in that same answer
  #
  # WHERE THE REFRESH TOKEN AND THE OPEN ID COME FROM (token_source): the stored
  # connection, TiktokConnection.current, first; the env pair only when no
  # connection is stored. When TikTok answers a refresh with a new refresh
  # token, the stored connection is updated (TiktokConnection#rotate!). The env
  # pair is read-only: nothing is written when it is the source.
  #
  # WHAT THE SIGN-IN ASKS FOR. Drafts only, by default: DEFAULT_SCOPES. The hub's
  # clip drafting uploads to the inbox (video.upload) and never publishes, and
  # TikTok refuses the whole sign-in with the error `scope` when the app lacks
  # any one scope asked for; a sandbox app without Direct Post has no
  # video.publish. Direct post is an explicit opt-in: TIKTOK_SCOPES, a
  # comma-separated list checked against KNOWN_SCOPES, which must still carry
  # the two drafting scopes.
  #
  # WHAT THE CONNECTION WAS GRANTED is read from TikTok, not from an env var:
  # every token refresh answers with `scope`, so the hub cannot hold a stale or
  # hopeful copy. ensure_direct_post! refuses when that answer lacks
  # video.publish, and also when it names no scope at all.
  #
  # Env vars:
  #   TIKTOK_CLIENT_KEY     — the developer app's client key
  #   TIKTOK_CLIENT_SECRET  — the developer app's client secret
  #   TIKTOK_REFRESH_TOKEN  — fallback only, for a server with no stored connection
  #   TIKTOK_OPEN_ID        — fallback only, the pair of that refresh token
  #   TIKTOK_SCOPES         — optional; unset means DEFAULT_SCOPES
  class OAuthClient
    AUTH_URL  = "https://www.tiktok.com/v2/auth/authorize/".freeze
    TOKEN_URL = "https://open.tiktokapis.com/v2/oauth/token/".freeze

    DIRECT_POST_SCOPE = "video.publish".freeze
    # Drafts only: who the account is, and an upload to its inbox.
    DEFAULT_SCOPES = %w[user.info.basic video.upload].freeze
    # Everything TIKTOK_SCOPES may name, in the order the sign-in sends it.
    KNOWN_SCOPES = [*DEFAULT_SCOPES, DIRECT_POST_SCOPE].freeze
    SCOPES_ENV = "TIKTOK_SCOPES".freeze
    CONNECT_PATH = "/admin/tiktok/connect".freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # TIKTOK_SCOPES names a scope the hub does not know, or drops one drafting needs.
    class InvalidScopes < Error; end
    # The connection does not hold the scope the call needs.
    class MissingScope < Error; end

    # Where the refresh token and the open id came from. `connection` is the
    # stored TiktokConnection, or nil when the env pair answered.
    TokenSource = Struct.new(:refresh_token, :open_id, :connection) do
      def stored? = !connection.nil?

      # Names the cached grant. A stored connection is named by its row and its
      # sign-in time, so a rotated refresh token keeps the entry and a new
      # sign-in drops it; the env pair is named by a digest of its token. The
      # two prefixes keep a stored connection and an env pair apart.
      def cache_id
        return "connection-#{connection.id}-#{connection.connected_at.to_i}" if stored?

        "env-#{Digest::SHA256.hexdigest(refresh_token)[0, 16]}"
      end
    end

    class << self
      # Stand-in for the token endpoint: (form params) -> [status Integer, body
      # String]. nil means TikTok itself. Set in tests only.
      attr_accessor :http

      # Stand-in for TikTok's side of the sign-in: an object answering
      # authorize_url and exchange_code as the two methods below do. nil means
      # TikTok itself. Set by config/initializers/tiktok_draft_stand_in.rb for
      # the e2e lane and a local demo, never in production.
      attr_accessor :sign_in_stand_in

      # Builds the user-facing authorize URL for the one-time OAuth handshake.
      def authorize_url(redirect_uri:, state:, scopes: nil)
        return sign_in_stand_in.authorize_url(redirect_uri:, state:, scopes:) if sign_in_stand_in

        ensure_app_creds!
        scopes ||= requested_scopes
        params = {
          client_key:    ENV.fetch("TIKTOK_CLIENT_KEY"),
          response_type: "code",
          scope:         scopes.join(","),
          redirect_uri:  redirect_uri,
          state:         state
        }
        "#{AUTH_URL}?#{URI.encode_www_form(params)}"
      end

      # Exchanges an authorization code for an access_token + refresh_token + open_id.
      # Returns the parsed JSON response.
      def exchange_code(code:, redirect_uri:)
        return sign_in_stand_in.exchange_code(code:, redirect_uri:) if sign_in_stand_in

        ensure_app_creds!
        post_token(
          client_key:    ENV.fetch("TIKTOK_CLIENT_KEY"),
          client_secret: ENV.fetch("TIKTOK_CLIENT_SECRET"),
          code:          code,
          grant_type:    "authorization_code",
          redirect_uri:  redirect_uri
        )
      end

      # The short-lived access token for a call to TikTok.
      def access_token = grant.fetch("access_token")

      # The scopes TikTok says this connection holds, from the token refresh.
      # Empty when TikTok named none.
      def granted_scopes = split_scopes(grant["scope"])

      # The scopes the sign-in asks for: DEFAULT_SCOPES, or TIKTOK_SCOPES when
      # it is set. Raises InvalidScopes for a list the sign-in must not send.
      def requested_scopes
        asked = split_scopes(ENV[SCOPES_ENV])
        return DEFAULT_SCOPES if asked.empty?

        unknown = asked - KNOWN_SCOPES
        if unknown.any?
          raise InvalidScopes, "#{SCOPES_ENV} names #{unknown.join(', ')}, which this server does not know. " \
                               "It may list: #{KNOWN_SCOPES.join(', ')}."
        end
        dropped = DEFAULT_SCOPES - asked
        if dropped.any?
          raise InvalidScopes, "#{SCOPES_ENV} leaves out #{dropped.join(', ')}, which drafting needs. " \
                               "Unset it for drafts only, or set it to #{KNOWN_SCOPES.join(',')} to add direct post."
        end
        KNOWN_SCOPES & asked
      end

      # Raises MissingScope unless this connection may publish to the public
      # feed. Every direct-post path calls it before asking TikTok to publish.
      # A grant that names no scope is refused too: unknown is not granted.
      def ensure_direct_post!
        granted = granted_scopes
        return if granted.include?(DIRECT_POST_SCOPE)

        if granted.empty?
          raise MissingScope, "TikTok did not say which permissions this connection holds, so a direct post is refused: " \
                              "it needs #{DIRECT_POST_SCOPE}. Connect again at #{CONNECT_PATH}."
        end
        raise MissingScope, "this TikTok connection was authorized for drafts only (granted: #{granted.join(', ')}). " \
                            "A direct post needs #{DIRECT_POST_SCOPE}: add Direct Post to the TikTok app, set " \
                            "#{SCOPES_ENV}=#{KNOWN_SCOPES.join(',')}, and connect again at #{CONNECT_PATH}. " \
                            "Send to drafts still works."
      end

      def open_id
        token_source&.open_id or raise NotConfigured, "no TikTok account is connected (sign in at #{CONNECT_PATH})"
      end

      def app_creds_present?
        ENV["TIKTOK_CLIENT_KEY"].present? && ENV["TIKTOK_CLIENT_SECRET"].present?
      end

      # The client key and secret, and a refresh token with its open id from
      # either source.
      def runtime_creds_present?
        app_creds_present? && !token_source.nil?
      end

      # The refresh token and open id in use: the stored connection first, then
      # the env pair (both of the two, or it is no source). nil when neither.
      def token_source
        connection = TiktokConnection.current
        return TokenSource.new(connection.refresh_token, connection.open_id, connection) if connection

        token = ENV["TIKTOK_REFRESH_TOKEN"]
        id = ENV["TIKTOK_OPEN_ID"]
        TokenSource.new(token, id, nil) if token.present? && id.present?
      end

      # A granted or asked scope list, as TikTok and TIKTOK_SCOPES write one:
      # names parted by commas, whitespace, or both.
      def split_scopes(list) = list.to_s.split(/[\s,]+/).reject(&:empty?).uniq

      private

      def ensure_app_creds!
        raise NotConfigured, "TIKTOK_CLIENT_KEY / TIKTOK_CLIENT_SECRET not set" unless app_creds_present?
      end

      def ensure_runtime_creds!
        return if runtime_creds_present?

        raise NotConfigured, "TikTok is not connected: this server needs TIKTOK_CLIENT_KEY and TIKTOK_CLIENT_SECRET, " \
                             "and a sign-in at #{CONNECT_PATH}"
      end

      # One refresh of the refresh token in use (token_source), cached for 50
      # minutes (TikTok's access tokens last 24 hours): the access token, and
      # the scope TikTok names with it. Nothing else from the answer is cached.
      # A refresh token TikTok rotated is saved to the stored connection here,
      # inside the refresh, before the grant is returned: the old one may be
      # dead already. The cache key (TokenSource#cache_id) turns with a new
      # sign-in, so it is never answered with the last connection's scope, and
      # does not turn with a rotation, so the entry is not stranded.
      def grant
        ensure_runtime_creds!
        source = token_source
        Rails.cache.fetch("tiktok:grant:#{source.cache_id}", expires_in: 50.minutes) do
          json = post_token(
            client_key:    ENV.fetch("TIKTOK_CLIENT_KEY"),
            client_secret: ENV.fetch("TIKTOK_CLIENT_SECRET"),
            grant_type:    "refresh_token",
            refresh_token: source.refresh_token
          )
          source.connection&.rotate!(json)
          { "access_token" => json["access_token"], "scope" => json["scope"].to_s }
        end
      end

      # A refusal carries TikTok's `error` and `error_description` and never
      # the answer's body: a body can hold a token. Each is taken only when it
      # is a String, so an object nested under either name is never printed.
      def post_token(params)
        code, body = (http || method(:net_http)).call(params)
        json = parse(body)
        unless (200..299).cover?(code) && json["access_token"].present?
          reason = [json["error"], json["error_description"]].grep(String).map(&:strip).reject(&:empty?).join(": ")
          raise Error, "TikTok token request failed (HTTP #{code}): #{reason.presence || 'TikTok gave no reason'}"[0, 400]
        end
        json
      end

      def parse(body)
        json = JSON.parse(body.to_s)
        json.is_a?(Hash) ? json : {}
      rescue JSON::ParserError
        {}
      end

      def net_http(params)
        uri = URI(TOKEN_URL)
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"]    = "application/x-www-form-urlencoded"
        req["Cache-Control"]   = "no-cache"
        req.set_form_data(params)
        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |h| h.request(req) }
        [resp.code.to_i, resp.body.to_s]
      rescue SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "could not reach TikTok (#{e.class.name})"
      end
    end
  end
end
