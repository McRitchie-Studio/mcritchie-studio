require "net/http"
require "uri"
require "json"
require "digest"

module Tiktok
  # OAuth 2.0 client for the TikTok Content Posting API.
  #
  # One-time setup flow:
  #   1. Visit /admin/tiktok/connect → redirects to TikTok auth page
  #   2. User logs into @turfmonstershow + grants video.upload + video.publish
  #   3. TikTok redirects back to /admin/tiktok/callback with ?code=...
  #   4. Callback page exchanges code for refresh_token + open_id
  #   5. The callback stores them as the TiktokConnection; nobody copies a token
  #
  # Per-post flow:
  #   Tiktok::OAuthClient.access_token  → exchanges refresh_token for short-lived access_token (cached 50 minutes)
  #
  # WHERE THE REFRESH TOKEN AND THE OPEN ID COME FROM (token_source): the stored
  # connection, TiktokConnection.current, first; the env pair only when no
  # connection is stored. When TikTok answers a refresh with a new refresh
  # token, the stored connection is updated (TiktokConnection#rotate!). The env
  # pair is read-only: nothing is written when it is the source.
  #
  # Env vars:
  #   TIKTOK_CLIENT_KEY     — from developer.tiktok.com (Client key); required
  #   TIKTOK_CLIENT_SECRET  — from developer.tiktok.com (Client secret); required
  #   TIKTOK_REFRESH_TOKEN  — fallback only, for a server with no stored connection
  #   TIKTOK_OPEN_ID        — fallback only, the pair of the refresh token
  class OAuthClient
    AUTH_URL  = "https://www.tiktok.com/v2/auth/authorize/".freeze
    TOKEN_URL = "https://open.tiktokapis.com/v2/oauth/token/".freeze

    DEFAULT_SCOPES = %w[user.info.basic video.upload video.publish].freeze
    CONNECT_PATH = "/admin/tiktok/connect".freeze

    class Error < StandardError; end
    class NotConfigured < Error; end

    # Where the refresh token and the open id came from. `connection` is the
    # stored TiktokConnection, or nil when the env pair answered.
    TokenSource = Struct.new(:refresh_token, :open_id, :connection) do
      def stored? = !connection.nil?

      # Names the cached access token. A stored connection is named by its row
      # and its sign-in time, so a rotated refresh token keeps the cache and a
      # new sign-in drops it; the env pair is named by a digest of its token.
      def cache_id
        return "connection-#{connection.id}-#{connection.connected_at.to_i}" if stored?

        "env-#{Digest::SHA256.hexdigest(refresh_token)[0, 16]}"
      end
    end

    class << self
      # Stand-in for TikTok's side of the sign-in: an object answering
      # authorize_url and exchange_code as the two methods below do. nil means
      # TikTok itself. Set by config/initializers/tiktok_draft_stand_in.rb for
      # the e2e lane and a local demo, never in production.
      attr_accessor :sign_in_stand_in

      # Builds the user-facing authorize URL for the one-time OAuth handshake.
      def authorize_url(redirect_uri:, state:, scopes: DEFAULT_SCOPES)
        return sign_in_stand_in.authorize_url(redirect_uri:, state:, scopes:) if sign_in_stand_in

        ensure_app_creds!
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

      # Exchanges the refresh token (token_source) for a short-lived
      # access_token. Cached in Rails.cache for ~50 minutes (TikTok access
      # tokens are 24h but cache generously to avoid hammering the token
      # endpoint). A refresh token TikTok rotated is saved to the stored
      # connection before the access token is returned.
      def access_token
        ensure_runtime_creds!
        source = token_source
        Rails.cache.fetch("tiktok:access_token:#{source.cache_id}", expires_in: 50.minutes) do
          json = post_token(
            client_key:    ENV.fetch("TIKTOK_CLIENT_KEY"),
            client_secret: ENV.fetch("TIKTOK_CLIENT_SECRET"),
            grant_type:    "refresh_token",
            refresh_token: source.refresh_token
          )
          source.connection&.rotate!(json)
          json["access_token"]
        end
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

      private

      def ensure_app_creds!
        raise NotConfigured, "TIKTOK_CLIENT_KEY / TIKTOK_CLIENT_SECRET not set" unless app_creds_present?
      end

      def ensure_runtime_creds!
        return if runtime_creds_present?

        raise NotConfigured, "TikTok is not connected: this server needs TIKTOK_CLIENT_KEY and TIKTOK_CLIENT_SECRET, " \
                             "and a sign-in at #{CONNECT_PATH}"
      end

      def post_token(params)
        uri = URI(TOKEN_URL)
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"]    = "application/x-www-form-urlencoded"
        req["Cache-Control"]   = "no-cache"
        req.set_form_data(params)
        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
        json = JSON.parse(resp.body || "{}")
        unless resp.is_a?(Net::HTTPSuccess) && json["access_token"]
          raise Error, "TikTok token request failed (#{resp.code}): #{resp.body}"
        end
        json
      end
    end
  end
end
