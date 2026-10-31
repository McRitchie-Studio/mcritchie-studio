require "net/http"
require "openssl"

module Media
  class Teams < Adapter
    # The Bot Connector REST API, as much of it as the hub uses, with an
    # app-only token (docs/agents/system/agent-message-loop.md, "Teams"). Built
    # to learn.microsoft.com, checked 2026-10-30:
    #
    #   TOKEN  POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
    #          (single-tenant; botframework.com when TEAMS_TENANT_ID is unset),
    #          grant_type=client_credentials, scope https://api.botframework.com/.default
    #          (azure/bot-service/rest-api/bot-framework-rest-connector-authentication).
    #          Cached until EXPIRY_MARGIN before its expires_in.
    #   REPLY  POST {serviceUrl}/v3/conversations/{conversationId}/activities/{activityId}
    #   SEND   POST {serviceUrl}/v3/conversations/{conversationId}/activities
    #          (bot-framework-rest-connector-send-and-receive-messages)
    #   NEW THREAD  POST {serviceUrl}/v3/conversations with isGroup and
    #          channelData.channel.id, answering { id, activityId }
    #          (resources/bot-v3/bot-conversations/bots-conv-proactive)
    #
    # The password (TEAMS_BOT_APP_PASSWORD) and the token never appear in an
    # error or a log line. Our bearer token is sent only to a serviceUrl on a
    # Microsoft Bot Connector host (TRUSTED_SERVICE_HOST), so even a stored
    # reference that went wrong cannot hand it to anyone else.
    #
    # NO IDEMPOTENCY KEY, so every outcome is sorted as Slack's are, and only
    # NotPosted is retried:
    #   NotPosted  provably not sent, worth another try: any failure getting the
    #              token (the activity was never sent), a connection that never
    #              opened, HTTP 429 (Retry-After kept), 412 (Microsoft: retry
    #              it), 401 (the token is dropped; the next try mints another).
    #   Refused    provably not sent, a retry would be refused too: 400, 403
    #              (blocked, not installed), 404, 413 MessageSizeTooBig, any
    #              other 4xx, or a serviceUrl that is not a Bot Connector host.
    #   Ambiguous  it MAY have been sent: a timeout or reset after the request
    #              went out, a TLS error, any HTTP 5xx (502 and 504 included,
    #              though Microsoft's rate-limit page says to retry them: a
    #              gateway timeout cannot prove the message was not delivered),
    #              or a 2xx whose body is not the Connector's JSON.
    class Client
      APP_ID_ENV = "TEAMS_BOT_APP_ID".freeze
      PASSWORD_ENV = "TEAMS_BOT_APP_PASSWORD".freeze
      TENANT_ENV = "TEAMS_TENANT_ID".freeze
      LOGIN = "https://login.microsoftonline.com".freeze
      SCOPE = "https://api.botframework.com/.default".freeze
      EXPIRY_MARGIN = 5.minutes
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15
      # Bot Connector hosts: the public smba.trafficmanager.net, the
      # *.botframework.com service URLs, and the GCC / GCC High / DoD hosts
      # (bots/how-to/conversations/send-proactive-messages).
      TRUSTED_SERVICE_HOST = /\A(?:smba\.trafficmanager\.net|[a-z0-9.-]+\.botframework\.com|[a-z0-9.-]+\.teams\.microsoft\.(?:com|us))\z/i

      # The process-wide token cache, keyed by app id.
      class TokenCache
        def initialize
          @mutex = Mutex.new
          @tokens = {}
        end

        def fetch(key, now)
          @mutex.synchronize do
            entry = @tokens[key]
            next entry[:token] if entry && entry[:expires_at] > now

            token, expires_at = yield
            @tokens[key] = { token: token, expires_at: expires_at }
            token
          end
        end

        def drop(key) = @mutex.synchronize { @tokens.delete(key) }

        def clear! = @mutex.synchronize { @tokens.clear }
      end

      def self.token_cache = @token_cache ||= TokenCache.new

      attr_reader :app_id

      # The transport is injectable: a test hands in a lambda taking
      # (method, url, headers, body) and answering [status, headers, body].
      def initialize(app_id: ENV[APP_ID_ENV], password: ENV[PASSWORD_ENV], tenant_id: ENV[TENANT_ENV],
                     transport: nil, token_cache: self.class.token_cache, now: -> { Time.current })
        @app_id = app_id.to_s.strip
        @password = password.to_s
        @tenant_id = tenant_id.to_s.strip
        @transport = transport || method(:http_request)
        @token_cache = token_cache
        @now = now
      end

      def configured? = @app_id.present? && @password.present?

      # The bot's own account on Teams.
      def bot_account = { id: "28:#{@app_id}" }

      # A reply under `activity_id` in `conversation_id` (for a channel thread,
      # the thread's ;messageid= conversation id). Answers the Connector's JSON
      # ({ "id" => the new activity's id }).
      def reply(service_url, conversation_id, activity_id, activity)
        path = "v3/conversations/#{escape(conversation_id)}/activities/#{escape(activity_id)}"
        connector(service_url, path, activity)
      end

      # A message into `conversation_id` that replies to nothing (a reply into
      # an existing channel thread when the id carries ;messageid=<root>).
      def send_to(service_url, conversation_id, activity)
        connector(service_url, "v3/conversations/#{escape(conversation_id)}/activities", activity)
      end

      # A new thread in channel `channel_id`: { "id" => conversation id,
      # "activityId" => the root message's id }.
      def create_thread(service_url, channel_id, activity, tenant_id: nil)
        body = { isGroup: true, bot: bot_account, activity: activity,
                 channelData: { channel: { id: channel_id }, tenant: ({ id: tenant_id } if tenant_id.present?) }.compact }
        connector(service_url, "v3/conversations", body)
      end

      def access_token
        @token_cache.fetch(@app_id, @now.call) { mint_token }
      end

      private

      def escape(id) = ERB::Util.url_encode(id.to_s)

      def connector(service_url, path, body)
        raise Teams::Refused.new("TEAMS_BOT_APP_ID / TEAMS_BOT_APP_PASSWORD are unset", code: "not_configured") unless configured?

        base = trusted_base(service_url)
        token = access_token
        status, headers, response = begin
          @transport.call(:post, "#{base}/#{path}",
                          { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json; charset=utf-8" },
                          body.to_json)
        rescue *Media::Http::NEVER_SENT => e
          raise Teams::NotPosted.new("Bot Connector: could not reach #{URI(base).host} (#{e.class})", code: "unreachable")
        rescue *Media::Http::MAYBE_SENT => e
          raise Teams::Ambiguous.new("Bot Connector: #{e.class} after the request was sent; it may have posted", code: "timeout")
        end
        classify(status.to_i, headers || {}, response.to_s)
      end

      def trusted_base(service_url)
        uri = URI(service_url.to_s)
        unless uri.is_a?(URI::HTTPS) && uri.host.to_s.match?(TRUSTED_SERVICE_HOST)
          raise Teams::Refused.new("serviceUrl #{uri.host.to_s[0, 60].inspect} is not a Bot Connector host; not sent",
                                   code: "untrusted_service_url")
        end

        service_url.to_s.delete_suffix("/")
      rescue URI::InvalidURIError
        raise Teams::Refused.new("serviceUrl is not a URL; not sent", code: "untrusted_service_url")
      end

      def classify(status, headers, body)
        if status == 429
          retry_after = header(headers, "retry-after").to_f
          raise Teams::NotPosted.new("Bot Connector: rate limited (429, retry after #{retry_after.round}s)",
                                     code: "ratelimited", retry_after: retry_after)
        end
        raise Teams::NotPosted.new("Bot Connector: HTTP 412; not posted, worth a retry", code: "http_412") if status == 412
        if status == 401
          @token_cache.drop(@app_id)
          raise Teams::NotPosted.new("Bot Connector: HTTP 401 (the token was refused; a new one is minted next try)",
                                     code: "unauthorized")
        end
        raise Teams::Ambiguous.new("Bot Connector: HTTP #{status}; it may have posted", code: "http_#{status}") if status >= 500
        if status >= 400 || status < 200
          raise Teams::Refused.new("Bot Connector: HTTP #{status} #{error_code(body)}".strip, code: "http_#{status}")
        end

        json = parse(body)
        raise Teams::Ambiguous.new("Bot Connector: HTTP #{status} with no Connector answer", code: "unreadable") unless json.is_a?(Hash)

        json
      end

      # The app-only token: [token, expires_at]. Every failure is a provable
      # non-send (the activity has not gone out).
      def mint_token
        raise Teams::Refused.new("TEAMS_BOT_APP_ID / TEAMS_BOT_APP_PASSWORD are unset", code: "not_configured") unless configured?

        url = "#{LOGIN}/#{@tenant_id.presence || 'botframework.com'}/oauth2/v2.0/token"
        form = URI.encode_www_form(grant_type: "client_credentials", client_id: @app_id, client_secret: @password, scope: SCOPE)
        status, _headers, body = begin
          @transport.call(:post, url, { "Content-Type" => "application/x-www-form-urlencoded" }, form)
        rescue *(Media::Http::NEVER_SENT + Media::Http::MAYBE_SENT) => e
          raise Teams::NotPosted.new("token: could not reach the login service (#{e.class})", code: "token_unreachable")
        end
        json = parse(body.to_s) || {}
        if status.to_i == 200 && json["access_token"].present?
          expires = json["expires_in"].to_i.positive? ? json["expires_in"].to_i : 3600
          return [ json["access_token"].to_s, @now.call + expires.seconds - EXPIRY_MARGIN ]
        end

        error = json["error"].to_s.presence || "http_#{status.to_i}"
        if status.to_i == 429 || status.to_i >= 500
          raise Teams::NotPosted.new("token: the login service answered #{error}", code: "token_unavailable")
        end

        raise Teams::Refused.new("token: the login service refused the bot's credentials (#{error})", code: "token_refused")
      end

      def error_code(body)
        json = parse(body)
        return "" unless json.is_a?(Hash)

        (json.dig("error", "code") || json["errorCode"]).to_s[0, 60]
      end

      def parse(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def header(headers, name)
        headers.find { |key, _| key.to_s.casecmp?(name) }&.last.then { |v| Array(v).first }
      end

      def http_request(_method, url, headers, body)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        headers.each { |key, value| request[key] = value }
        request.body = body
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT,
                                                       read_timeout: READ_TIMEOUT, write_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end
        [ response.code.to_i, response.each_header.to_h, response.body ]
      end
    end
  end
end
