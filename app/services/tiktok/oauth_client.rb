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
  #   4. The callback exchanges the code and shows the refresh token, the open
  #      id and the scope TikTok granted, once, for filing in 1Password
  #
  # Per-post flow:
  #   access_token    exchanges TIKTOK_REFRESH_TOKEN for a short-lived token (cached 50 min)
  #   granted_scopes  the scope TikTok names in that same answer
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
  #   TIKTOK_REFRESH_TOKEN  — long-lived refresh token from the sign-in
  #   TIKTOK_OPEN_ID        — the TikTok account's open_id (shown with the refresh token)
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

    class << self
      # Stand-in for the token endpoint: (form params) -> [status Integer, body
      # String]. nil means TikTok itself. Set in tests only.
      attr_accessor :http

      # Builds the user-facing authorize URL for the one-time OAuth handshake.
      def authorize_url(redirect_uri:, state:, scopes: nil)
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

      # One refresh of TIKTOK_REFRESH_TOKEN, cached for 50 minutes (TikTok's
      # access tokens last 24 hours): the access token, and the scope TikTok
      # names with it. Nothing else from the answer is kept. The cache key
      # turns with the refresh token, so a new sign-in is never answered with
      # the last connection's scope.
      def grant
        ensure_runtime_creds!
        connection = Digest::SHA256.hexdigest(ENV.fetch("TIKTOK_REFRESH_TOKEN"))[0, 16]
        Rails.cache.fetch("tiktok:grant:#{connection}", expires_in: 50.minutes) do
          json = post_token(
            client_key:    ENV.fetch("TIKTOK_CLIENT_KEY"),
            client_secret: ENV.fetch("TIKTOK_CLIENT_SECRET"),
            grant_type:    "refresh_token",
            refresh_token: ENV.fetch("TIKTOK_REFRESH_TOKEN")
          )
          { "access_token" => json["access_token"], "scope" => json["scope"].to_s }
        end
      end

      def split_scopes(list) = list.to_s.split(",").map(&:strip).reject(&:empty?).uniq

      # A refusal carries TikTok's `error` and `error_description` and never
      # the answer's body: a body can hold a token.
      def post_token(params)
        code, body = (http || method(:net_http)).call(params)
        json = parse(body)
        unless (200..299).cover?(code) && json["access_token"].present?
          reason = [json["error"], json["error_description"]].map { |part| part.to_s.strip }.reject(&:empty?).join(": ")
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
