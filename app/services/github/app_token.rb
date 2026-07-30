require "base64"
require "json"
require "openssl"
require "time"

module Github
  # Mints and caches a GitHub App INSTALLATION token for the board's server-side
  # GitHub API calls, replacing the static GITHUB_TOKEN PAT that — after the
  # 2026-07-29 org migration to McRitchie-Studio — can read PUBLIC repos only.
  # Private-repo reads (e.g. mcritchie-industries) fail with the static PAT; an
  # App installation token (contents/checks scope on every installed repo) reads
  # both. See docs/agents/modules/deployment.md.
  #
  # ENV contract (the ship lane provisions these as Heroku config vars). All are
  # optional — when App creds are ABSENT the resolver falls back to the static
  # GITHUB_TOKEN so dev/CI/local keep working unchanged:
  #
  #   GITHUB_APP_ID                 numeric App id (the agent App, e.g. github.mcritchie-agent)
  #   GITHUB_APP_PRIVATE_KEY        the App's RSA private key as PEM text (the .pem, not a passphrase)
  #   GITHUB_APP_INSTALLATION_ID    (optional) installation id to mint for; when blank it is
  #                                 discovered from /app/installations by the match below
  #   GITHUB_APP_INSTALLATION_MATCH (optional) substring the installation account login must
  #                                 contain when discovering (default "mcritchie")
  #   GITHUB_TOKEN                  the static fallback token (dev/CI/local, or if minting fails)
  #
  # The mint mirrors bin/gh-app-mint-token (the shipped formalize-app-identity-wiring
  # pattern): build an RS256 JWT signed by the App key (iss = app id, ~9-min TTL),
  # GET /app/installations to resolve the installation, then POST
  # /app/installations/{id}/access_tokens for the ~1h installation token. We cache
  # that token in Rails.cache and refresh REFRESH_SKEW before GitHub's expiry
  # (~50m in practice) so per-request Github::Client instances share one mint.
  class AppToken
    APP_ID_ENV = "GITHUB_APP_ID".freeze
    PRIVATE_KEY_ENV = "GITHUB_APP_PRIVATE_KEY".freeze
    INSTALLATION_ID_ENV = "GITHUB_APP_INSTALLATION_ID".freeze
    INSTALLATION_MATCH_ENV = "GITHUB_APP_INSTALLATION_MATCH".freeze
    FALLBACK_TOKEN_ENV = "GITHUB_TOKEN".freeze

    DEFAULT_INSTALLATION_MATCH = "mcritchie".freeze
    CACHE_KEY = "github:app_installation_token:v1".freeze
    # Backstop expiry on the cache entry itself. We drive refresh off the stored
    # GitHub expiry (below), so this is only a floor for a wedged clock.
    CACHE_BACKSTOP_TTL = 55.minutes
    # Refresh the token this long BEFORE GitHub's hard 1h expiry (→ reuse ~50m).
    REFRESH_SKEW = 10.minutes
    JWT_TTL_SECONDS = 540 # 9 minutes — GitHub's 10-minute JWT ceiling, minus drift.
    JWT_CLOCK_DRIFT_SECONDS = 60
    DEFAULT_TOKEN_TTL = 1.hour # assumed when GitHub omits expires_at.

    class MintError < StandardError; end

    class << self
      # The token Github::Client should authenticate with: a minted + cached App
      # installation token when App creds are configured, else the static fallback.
      def resolve(**opts)
        new(**opts).resolve
      end

      def reset_cache!(cache: Rails.cache)
        cache.delete(CACHE_KEY)
      end
    end

    def initialize(
      app_id: ENV[APP_ID_ENV],
      private_key_pem: ENV[PRIVATE_KEY_ENV],
      installation_id: ENV[INSTALLATION_ID_ENV],
      installation_match: ENV.fetch(INSTALLATION_MATCH_ENV, DEFAULT_INSTALLATION_MATCH),
      fallback_token: ENV[FALLBACK_TOKEN_ENV],
      cache: Rails.cache,
      logger: Rails.logger,
      now: -> { Time.now.utc },
      client_factory: ->(jwt) { Github::Client.new(token: jwt, logger: logger) }
    )
      @app_id = app_id.to_s.strip
      @private_key_pem = private_key_pem.to_s
      @installation_id = installation_id.to_s.strip.presence
      @installation_match = installation_match.to_s.strip.downcase.presence || DEFAULT_INSTALLATION_MATCH
      @fallback_token = fallback_token.to_s.strip.presence
      @cache = cache
      @logger = logger
      @now = now
      @client_factory = client_factory
    end

    def resolve
      return @fallback_token unless configured?

      cached = fresh_cached_token
      return cached if cached

      mint_and_cache
    rescue StandardError => e
      # Never let a mint hiccup take the board down: log loudly, then reuse a
      # still-valid cached token if we have one, else the static fallback.
      @logger&.warn("Github::AppToken mint failed (#{e.class}: #{e.message}); falling back to GITHUB_TOKEN")
      unexpired_cached_token || @fallback_token
    end

    # App creds present → we can (and should) mint. Absent → fallback path.
    def configured?
      @app_id.present? && @private_key_pem.present?
    end

    private

    def now
      @now.call.utc
    end

    # A cached token still comfortably inside its TTL (before the refresh skew).
    def fresh_cached_token
      entry = read_entry
      return nil unless entry

      now < (entry[:expires_at] - REFRESH_SKEW) ? entry[:token] : nil
    end

    # A cached token that has not yet passed GitHub's hard expiry — usable as a
    # last resort when a refresh mint fails.
    def unexpired_cached_token
      entry = read_entry
      return nil unless entry
      return nil if now >= entry[:expires_at]

      entry[:token]
    end

    def read_entry
      entry = @cache.read(CACHE_KEY)
      return nil unless entry.is_a?(Hash)
      return nil if entry[:token].blank? || entry[:expires_at].blank?

      entry
    end

    def mint_and_cache
      token, expires_at = mint_installation_token
      @cache.write(CACHE_KEY, { token: token, expires_at: expires_at }, expires_in: CACHE_BACKSTOP_TTL)
      token
    end

    # Returns [installation_token, expires_at]. Mirrors bin/gh-app-mint-token.
    def mint_installation_token
      client = @client_factory.call(build_jwt)
      installation_id = @installation_id || discover_installation_id(client)
      body = client.post("/app/installations/#{installation_id}/access_tokens")
      token = body.is_a?(Hash) ? body["token"].presence : nil
      raise MintError, "access_tokens response carried no token" unless token

      expires_at = parse_expires_at(body.is_a?(Hash) ? body["expires_at"] : nil)
      [token, expires_at]
    end

    def discover_installation_id(client)
      installations = client.get("/app/installations")
      raise MintError, "expected an installation list, got #{installations.class}" unless installations.is_a?(Array)

      installation = installations.find do |candidate|
        candidate.is_a?(Hash) && candidate.dig("account", "login").to_s.downcase.include?(@installation_match)
      end
      raise MintError, "no installation whose account matches #{@installation_match.inspect}" unless installation

      installation.fetch("id")
    end

    def build_jwt
      key = OpenSSL::PKey::RSA.new(@private_key_pem)
      issued = now.to_i
      header = jwt_segment("alg" => "RS256", "typ" => "JWT")
      payload = jwt_segment(
        "iat" => issued - JWT_CLOCK_DRIFT_SECONDS,
        "exp" => issued + JWT_TTL_SECONDS,
        "iss" => @app_id
      )
      signature = Base64.urlsafe_encode64(
        key.sign(OpenSSL::Digest::SHA256.new, "#{header}.#{payload}"), padding: false
      )
      "#{header}.#{payload}.#{signature}"
    rescue OpenSSL::OpenSSLError => e
      raise MintError, "GITHUB_APP_PRIVATE_KEY is not a valid RSA private key (#{e.message})"
    end

    def jwt_segment(hash)
      Base64.urlsafe_encode64(JSON.generate(hash), padding: false)
    end

    def parse_expires_at(raw)
      Time.iso8601(raw.to_s).utc
    rescue ArgumentError, TypeError
      now + DEFAULT_TOKEN_TTL
    end
  end
end
