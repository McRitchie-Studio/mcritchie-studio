require "net/http"
require "jwt"

module AgentMessages
  # Verifies the Bot Framework JWT on every request to POST
  # /webhooks/teams/messages (Webhooks::TeamsMessagesController): the WHOLE
  # security story of a public endpoint, as the HMAC is for Slack's. Built to
  # Microsoft's "Authenticate requests from the Bot Connector service to your
  # bot" (https://learn.microsoft.com/en-us/azure/bot-service/rest-api/
  # bot-framework-rest-connector-authentication, checked 2026-10-30), every
  # requirement it lists:
  #
  #   1. `Authorization: Bearer <JWT>`.
  #   2. A well-formed JWT whose header names a `kid` and alg RS256 (the OpenID
  #      metadata's id_token_signing_alg_values_supported).
  #   3. iss is exactly https://api.botframework.com.
  #   4. aud is our bot's Microsoft App id (TEAMS_BOT_APP_ID).
  #   5. Within its validity (exp, nbf), with Microsoft's 5-minute clock skew.
  #   6. Signed by a key in the Bot Connector's JWKS, found through the OpenID
  #      metadata at https://login.botframework.com/v1/.well-known/openidconfiguration.
  #   7. Its serviceUrl claim equals the activity's serviceUrl (so a token
  #      minted for one service URL cannot steer our replies, and our bot
  #      token, to another).
  #   + The signing key's `endorsements` include the activity's channelId
  #      (msteams); without the endorsement the answer is 403, as the page says.
  #
  # KEYS. The JWKS is cached per process for KEYS_TTL (Microsoft: refresh at
  # least once every 24 hours). A token whose kid is not in the cache refetches
  # ONCE (a key Microsoft just rotated in), at most once per REFETCH_GAP, so a
  # flood of made-up kids cannot turn into a flood of fetches.
  #
  # The token is never logged and never appears in a reason.
  class TeamsAuth
    OPENID_URL = "https://login.botframework.com/v1/.well-known/openidconfiguration".freeze
    ISSUER = "https://api.botframework.com".freeze
    ALGORITHM = "RS256".freeze
    LEEWAY = 300
    KEYS_TTL = 12.hours
    REFETCH_GAP = 5.minutes
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5

    # ok: whether the request may be read; status: the HTTP status to answer
    # otherwise (401, or 403 for a missing endorsement); reason: why, for the
    # log (never the token); claims: the verified payload.
    Result = Struct.new(:ok, :status, :reason, :claims, keyword_init: true) do
      def ok? = ok == true
    end

    class KeysUnavailable < StandardError; end

    # The process-wide JWKS cache: { kid => jwk hash }, when it was fetched and
    # when it was last refetched for an unknown kid.
    class KeyCache
      attr_accessor :keys, :fetched_at, :refetched_at

      def initialize
        @mutex = Mutex.new
        reset!
      end

      def synchronize(&) = @mutex.synchronize(&)

      def reset!
        @keys = {}
        @fetched_at = nil
        @refetched_at = nil
      end
    end

    def self.key_cache = @key_cache ||= KeyCache.new

    # `fetcher` takes a URL and answers its body (tests hand in a local JWKS).
    def initialize(app_id:, fetcher: nil, cache: self.class.key_cache, now: -> { Time.current })
      @app_id = app_id.to_s
      @fetcher = fetcher || method(:http_get)
      @cache = cache
      @now = now
    end

    def verify(authorization, activity)
      activity ||= {}
      token = bearer(authorization)
      return refuse("no Bearer token in Authorization") unless token
      return refuse("TEAMS_BOT_APP_ID is unset") if @app_id.empty?

      header = unverified_header(token)
      return refuse("not a JWT") unless header
      return refuse("alg #{header['alg'].to_s[0, 10]} is not #{ALGORITHM}") unless header["alg"] == ALGORITHM

      kid = header["kid"].to_s
      return refuse("no kid in the JWT header") if kid.empty?

      jwk = key_for(kid)
      return refuse("unknown signing key #{kid[0, 40]}") unless jwk

      claims = decode(token, jwk)
      return claims if claims.is_a?(Result)

      service_url = activity["serviceUrl"].to_s
      unless service_url.present? && claims["serviceUrl"].to_s == service_url
        return refuse("the serviceUrl claim does not match the activity's serviceUrl")
      end

      channel = activity["channelId"].to_s
      unless Array(jwk["endorsements"]).map(&:to_s).include?(channel) && channel.present?
        return refuse("the signing key is not endorsed for channel #{channel[0, 20].inspect}", status: 403)
      end

      Result.new(ok: true, status: 200, claims: claims)
    rescue KeysUnavailable => e
      refuse("the Bot Framework signing keys could not be fetched (#{e.message})")
    end

    private

    def bearer(authorization)
      scheme, token = authorization.to_s.split(" ", 2)
      return nil unless scheme.to_s.casecmp?("Bearer") && token.to_s.strip.present?

      token.strip
    end

    def unverified_header(token)
      header = JWT.decode(token, nil, false)[1]
      header.is_a?(Hash) ? header : nil
    rescue JWT::DecodeError, JSON::ParserError
      nil
    end

    # The verified claims, or a refusal Result.
    def decode(token, jwk)
      key = JWT::JWK.new(jwk.slice("kty", "n", "e", "kid")).verify_key
      claims, = JWT.decode(token, key, true, algorithms: [ ALGORITHM ], iss: ISSUER, verify_iss: true,
                                             aud: @app_id, verify_aud: true, verify_expiration: true,
                                             verify_not_before: true, leeway: LEEWAY,
                                             required_claims: %w[exp iss aud])
      claims
    rescue JWT::ExpiredSignature
      refuse("the token has expired")
    rescue JWT::InvalidIssuerError
      refuse("the issuer is not #{ISSUER}")
    rescue JWT::InvalidAudError
      refuse("the audience is not this bot's app id")
    rescue JWT::VerificationError
      refuse("the signature does not verify")
    rescue JWT::DecodeError, JWT::JWKError, OpenSSL::PKey::PKeyError, ArgumentError => e
      refuse("the token does not verify (#{e.class.name.demodulize})")
    end

    # The JWK for `kid`: from the cache while it is fresh, else after a fetch;
    # an unknown kid refetches once (at most once per REFETCH_GAP).
    def key_for(kid)
      @cache.synchronize do
        stale_refresh! if @cache.fetched_at.nil? || @cache.fetched_at < @now.call - KEYS_TTL
        next @cache.keys[kid] if @cache.keys.key?(kid)

        if @cache.refetched_at.nil? || @cache.refetched_at < @now.call - REFETCH_GAP
          @cache.refetched_at = @now.call
          refresh!
        end
        @cache.keys[kid]
      end
    end

    # A due refresh that fails keeps the keys already held (Microsoft's keys are
    # stable); with none held it raises.
    def stale_refresh!
      refresh!
    rescue KeysUnavailable
      raise if @cache.keys.empty?

      # Try again in REFETCH_GAP, not on every request.
      @cache.fetched_at = @now.call - KEYS_TTL + REFETCH_GAP
      Rails.logger.warn("[teams] the Bot Framework JWKS refresh failed; keeping the #{@cache.keys.size} keys held")
    end

    def refresh!
      metadata = parse(@fetcher.call(OPENID_URL))
      algs = Array(metadata["id_token_signing_alg_values_supported"])
      raise KeysUnavailable, "the metadata does not offer #{ALGORITHM}" if algs.any? && !algs.include?(ALGORITHM)

      jwks_uri = metadata["jwks_uri"].to_s
      raise KeysUnavailable, "the metadata names no https jwks_uri" unless jwks_uri.start_with?("https://")

      keys = Array(parse(@fetcher.call(jwks_uri))["keys"]).select { |k| k.is_a?(Hash) && k["kid"].present? }
      raise KeysUnavailable, "the JWKS lists no keys" if keys.empty?

      @cache.keys = keys.to_h { |k| [ k["kid"].to_s, k ] }
      @cache.fetched_at = @now.call
    end

    def parse(body)
      json = JSON.parse(body.to_s)
      raise KeysUnavailable, "not a JSON object" unless json.is_a?(Hash)

      json
    rescue JSON::ParserError
      raise KeysUnavailable, "not JSON"
    end

    def http_get(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      raise KeysUnavailable, "HTTP #{response.code} from #{uri.host}" unless response.code.to_i == 200

      response.body
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => e
      raise KeysUnavailable, "#{e.class.name} from #{uri&.host}"
    end

    def refuse(reason, status: 401) = Result.new(ok: false, status: status, reason: reason)
  end
end
