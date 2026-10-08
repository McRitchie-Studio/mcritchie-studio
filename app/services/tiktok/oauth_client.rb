require "net/http"
require "uri"
require "json"

module Tiktok
  # OAuth 2.0 client for the TikTok Content Posting API.
  #
  # One-time setup flow:
  #   1. Visit /admin/tiktok/connect → redirects to TikTok auth page
  #   2. User logs into @turfmonstershow + grants video.upload + video.publish
  #   3. TikTok redirects back to /admin/tiktok/callback with ?code=...
  #   4. Callback page exchanges code for refresh_token + open_id
  #   5. User copies the displayed values into .env
  #
  # Per-post flow:
  #   Tiktok::OAuthClient.access_token  → exchanges refresh_token for short-lived access_token (cached 1 hour)
  #
  # Required env vars:
  #   TIKTOK_CLIENT_KEY     — from developer.tiktok.com (Client key)
  #   TIKTOK_CLIENT_SECRET  — from developer.tiktok.com (Client secret)
  #   TIKTOK_REFRESH_TOKEN  — long-lived refresh token from initial OAuth handshake
  #   TIKTOK_OPEN_ID        — TikTok account open_id (returned with the refresh token)
  class OAuthClient
    AUTH_URL  = "https://www.tiktok.com/v2/auth/authorize/".freeze
    TOKEN_URL = "https://open.tiktokapis.com/v2/oauth/token/".freeze

    DEFAULT_SCOPES = %w[user.info.basic video.upload video.publish].freeze

    class Error < StandardError; end
    class NotConfigured < Error; end

    class << self
      # Stand-in for the token endpoint: (form params) -> [status Integer, body
      # String]. nil means TikTok itself. Set in tests only.
      attr_accessor :http

      # Builds the user-facing authorize URL for the one-time OAuth handshake.
      def authorize_url(redirect_uri:, state:, scopes: DEFAULT_SCOPES)
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
        ensure_app_creds!
        post_token(
          client_key:    ENV.fetch("TIKTOK_CLIENT_KEY"),
          client_secret: ENV.fetch("TIKTOK_CLIENT_SECRET"),
          code:          code,
          grant_type:    "authorization_code",
          redirect_uri:  redirect_uri
        )
      end

      # Exchanges TIKTOK_REFRESH_TOKEN for a short-lived access_token. Cached
      # in Rails.cache for ~50 minutes (TikTok access tokens are 24h but cache
      # generously to avoid hammering the token endpoint).
      def access_token
        ensure_runtime_creds!
        Rails.cache.fetch("tiktok:access_token", expires_in: 50.minutes) do
          json = post_token(
            client_key:    ENV.fetch("TIKTOK_CLIENT_KEY"),
            client_secret: ENV.fetch("TIKTOK_CLIENT_SECRET"),
            grant_type:    "refresh_token",
            refresh_token: ENV.fetch("TIKTOK_REFRESH_TOKEN")
          )
          json["access_token"] or raise Error, "refresh response missing access_token: #{json.inspect}"
        end
      end

      def open_id
        ENV.fetch("TIKTOK_OPEN_ID") { raise NotConfigured, "TIKTOK_OPEN_ID not set" }
      end

      def app_creds_present?
        ENV["TIKTOK_CLIENT_KEY"].present? && ENV["TIKTOK_CLIENT_SECRET"].present?
      end

      def runtime_creds_present?
        app_creds_present? &&
          ENV["TIKTOK_REFRESH_TOKEN"].present? &&
          ENV["TIKTOK_OPEN_ID"].present?
      end

      private

      def ensure_app_creds!
        raise NotConfigured, "TIKTOK_CLIENT_KEY / TIKTOK_CLIENT_SECRET not set" unless app_creds_present?
      end

      def ensure_runtime_creds!
        raise NotConfigured, "TikTok creds incomplete (need CLIENT_KEY/CLIENT_SECRET/REFRESH_TOKEN/OPEN_ID)" unless runtime_creds_present?
      end

      def post_token(params)
        code, body = (http || method(:net_http)).call(params)
        json = JSON.parse(body.presence || "{}")
        unless (200..299).cover?(code) && json["access_token"]
          raise Error, "TikTok token request failed (#{code}): #{body}"
        end
        json
      end

      def net_http(params)
        uri = URI(TOKEN_URL)
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"]    = "application/x-www-form-urlencoded"
        req["Cache-Control"]   = "no-cache"
        req.set_form_data(params)
        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
        [resp.code.to_i, resp.body.to_s]
      end
    end
  end
end
