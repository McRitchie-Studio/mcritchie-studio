require "net/http"
require "openssl"
require "uri"
require "json"

module Msgraph
  # App-only Microsoft Graph for a Microsoft 365 tenant (MsgraphConnection):
  # the `admin_grant` method of config/integrations.yml, on the hub's own
  # /admin/msgraph page and the /integrations Microsoft 365 card first.
  #
  #   1. /admin/msgraph/connect redirects a tenant administrator to Microsoft's
  #      admin-consent endpoint (AUTH_URL), which asks them to approve every
  #      application permission the app registration lists (PERMISSIONS).
  #   2. Microsoft redirects to /admin/msgraph/callback with ?tenant=<GUID>,
  #      ?admin_consent=True and the state (the redirect registered on the app)
  #   3. The callback stores MsgraphConnection for that tenant
  #
  # Reads then ask TOKEN_URL (the tenant's own token endpoint) for an access
  # token with the client-credentials grant and the Graph `.default` scope.
  # That flow answers no refresh token, so none is stored: the access token is
  # cached in THIS PROCESS'S MEMORY only, per tenant, until shortly before it
  # expires (EXPIRY_MARGIN). A restart forgets it and the next read asks again.
  #
  # Every URL, parameter and answer here is as Microsoft documents them:
  #   learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow
  #
  # NO REVOKE. Consent is removed in the tenant (Enterprise applications), not
  # by an API call from here, so Disconnect deletes the stored row and the
  # cached token and says so.
  #
  # Env vars (names only; values live in 1Password and Heroku config). These are
  # the multi-tenant Entra app registration's, not the Teams bot's (TEAMS_BOT_*):
  #   MSGRAPH_CLIENT_ID      the app registration's Application (client) ID
  #   MSGRAPH_CLIENT_SECRET  its client secret
  class OAuthClient
    LOGIN_HOST = "https://login.microsoftonline.com".freeze
    # `common`: the tenant is not known until its administrator signs in.
    AUTH_URL = "#{LOGIN_HOST}/common/adminconsent".freeze
    SCOPE = "https://graph.microsoft.com/.default".freeze
    ENV_NAMES = %w[MSGRAPH_CLIENT_ID MSGRAPH_CLIENT_SECRET].freeze
    # The application permissions the app registration must list, every one a
    # read (each is the least-privileged Application permission for its call;
    # Msgraph::Reader names which). Admin consent grants exactly these.
    PERMISSIONS = %w[User.Read.All Team.ReadBasic.All Sites.Read.All Files.Read.All Organization.Read.All].freeze
    # A cached token is dropped this long before Microsoft says it expires.
    EXPIRY_MARGIN = 5.minutes

    # What reaching Microsoft can raise below HTTP: TLS, refused, timed out, DNS.
    NETWORK_ERRORS = [ OpenSSL::SSL::SSLError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout ].freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # The tenant does not let the app in: Microsoft answers `unauthorized_client`
    # when the app is not found in, or not enabled for, the tenant (AADSTS700016,
    # AADSTS7000112; learn.microsoft.com/entra/identity-platform/reference-error-codes).
    # A permission removed from a consented app still yields a token; its read
    # then answers a Graph 403 (Reader's Error), not Revoked.
    class Revoked < Error; end

    Token = Struct.new(:value, :expires_at)

    class << self
      # Stand-in for the token endpoint: (url, form) -> [status, body]. nil
      # means Microsoft itself. Set in tests, the e2e lane and a local demo only.
      attr_accessor :http

      # Stand-in for Microsoft's admin-consent page (authorize_url only), for
      # the e2e lane and a local demo. Never production. The token requests
      # still run through .http, so the grant and the cache are the real ones.
      attr_accessor :sign_in_stand_in

      def configured? = ENV_NAMES.all? { |name| ENV[name].present? }

      # Can a Connect start on this server: the app registration is set, or the stand-in is.
      def connectable? = configured? || !sign_in_stand_in.nil?

      # Where an administrator approves the app for their tenant.
      def authorize_url(redirect_uri:, state:)
        return sign_in_stand_in.authorize_url(redirect_uri:, state:) if sign_in_stand_in

        ensure_configured!
        "#{AUTH_URL}?#{URI.encode_www_form(client_id: ENV.fetch('MSGRAPH_CLIENT_ID'), redirect_uri:, state:)}"
      end

      # The token endpoint of one tenant (by its GUID).
      def token_url(tenant_id) = "#{LOGIN_HOST}/#{ERB::Util.url_encode(tenant_id.to_s)}/oauth2/v2.0/token"

      # An app-only access token for the tenant: the cached one while it is
      # fresh, else a new client-credentials grant, cached until EXPIRY_MARGIN
      # before it expires. Raises Revoked when the tenant refuses the app.
      def access_token(tenant_id, now: Time.current)
        key = tenant_id.to_s.downcase
        cached = cache_lock.synchronize { cache[key] }
        return cached.value if cached && cached.expires_at > now

        answer = post(token_url(key), grant_type: "client_credentials", scope: SCOPE)
        value = answer["access_token"].presence or raise Error, "Microsoft answered a token request with no access token"
        lifetime = answer["expires_in"].to_i.seconds
        cache_lock.synchronize { cache[key] = Token.new(value, now + lifetime - EXPIRY_MARGIN) }
        value
      end

      # Drops the cached token of one tenant, or every tenant's.
      def forget!(tenant_id = nil)
        cache_lock.synchronize { tenant_id ? cache.delete(tenant_id.to_s.downcase) : cache.clear }
      end

      # How many tenants have a token cached in this process (for tests and the page).
      def cached_count = cache_lock.synchronize { cache.size }

      private

      def cache = (@cache ||= {})
      def cache_lock = (@cache_lock ||= Mutex.new)

      def ensure_configured!
        raise NotConfigured, "#{ENV_NAMES.join(' and ')} are not set on this server" unless configured? || http
      end

      def post(url, form)
        ensure_configured!
        form = form.merge(client_id: ENV["MSGRAPH_CLIENT_ID"].to_s, client_secret: ENV["MSGRAPH_CLIENT_SECRET"].to_s)
        status, body = call(url, form)
        json = JSON.parse(body.to_s) rescue {}
        json = {} unless json.is_a?(Hash)
        return json if status == 200

        detail = json["error_description"].to_s.lines.first.to_s.strip.presence || json["error"] || "no detail"
        raise Revoked, "the app is not found in, or not enabled for, the tenant (#{json['error']}); an administrator consents again" if json["error"] == "unauthorized_client"

        raise Error, "Microsoft answered #{status}: #{detail}"
      end

      def call(url, form)
        return http.call(url, form) if http

        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(form)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
        [ response.code.to_i, response.body ]
      rescue *NETWORK_ERRORS => e
        raise Error, "Microsoft could not be reached: #{e.class}"
      end
    end
  end
end
