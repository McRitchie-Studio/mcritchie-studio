require "net/http"
require "openssl"

module Media
  class Slack < Adapter
    # The Slack Web API, as much of it as the hub uses: chat.postMessage (with
    # chat:write.customize's username and icon_url) and users.info. The bot token
    # is SLACK_BOT_TOKEN (1Password slack.mcritchie-studio.applications,
    # `credential`); it never appears in an error or a log line.
    #
    # NO NONCE. Slack's chat.postMessage has no idempotency key, so every outcome
    # is sorted into one of three, and only the first may be retried:
    #
    #   NotPosted   PROVABLY not posted and worth another try: HTTP 429 (its
    #               Retry-After kept), or ok:false with a transient error
    #               (ratelimited, service_unavailable, request_timeout, …).
    #   Refused     PROVABLY not posted, and another try would be refused too:
    #               ok:false with anything else (channel_not_found,
    #               not_in_channel, invalid_auth, msg_too_long, …).
    #   Ambiguous   it MAY have posted: a timeout or dropped connection after the
    #               request was sent, an HTTP 5xx, ok:false fatal_error or
    #               internal_error (Slack says some of the call may have run), or
    #               a body that is not Slack's JSON. Never blind-retried.
    #
    # A connection that never opened (DNS, refused, connect timeout) is NotPosted:
    # no byte reached Slack. A TLS error is Ambiguous: OpenSSL raises SSLError for
    # a peer that drops mid-response too ("SSL_read: unexpected eof").
    class Client
      API = "https://slack.com/api/".freeze
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      # ok:false errors that say "not posted, try again later".
      TRANSIENT_ERRORS = %w[ratelimited rate_limited service_unavailable request_timeout team_added_to_org].freeze
      # ok:false errors that say "something ran, maybe the post": never retried.
      AMBIGUOUS_ERRORS = %w[fatal_error internal_error].freeze

      NEVER_SENT = [ SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                     Net::OpenTimeout ].freeze
      MAYBE_SENT = [ OpenSSL::SSL::SSLError, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, EOFError, IOError,
                     Errno::ECONNRESET, Errno::EPIPE, SystemCallError ].freeze

      # The transport is injectable: a test hands in a lambda taking
      # (method, params, token) and answering [status, headers, body].
      def initialize(token: ENV[Slack::TOKEN_ENV], transport: nil)
        @token = token.to_s
        @transport = transport || method(:http_post)
      end

      def configured? = @token.present?

      # chat.postMessage. Answers Slack's JSON (ok, ts, channel, message).
      def post_message(params)
        call("chat.postMessage", params)
      end

      # A user's display name, or nil (users:read; best effort).
      def user_name(user_id)
        body = call("users.info", { user: user_id })
        profile = body.dig("user", "profile") || {}
        profile["display_name"].presence || profile["real_name"].presence || body.dig("user", "name").presence
      rescue Slack::Error
        nil
      end

      def call(method, params)
        raise Slack::Refused.new("SLACK_BOT_TOKEN is unset", code: "not_configured") unless configured?

        status, headers, body = begin
          @transport.call(method, params, @token)
        rescue *NEVER_SENT => e
          raise Slack::NotPosted.new("#{method}: could not reach Slack (#{e.class})", code: "unreachable")
        rescue *MAYBE_SENT => e
          raise Slack::Ambiguous.new("#{method}: #{e.class} after the request was sent; it may have posted", code: "timeout")
        end
        classify(method, status.to_i, headers || {}, body.to_s)
      end

      private

      def classify(method, status, headers, body)
        if status == 429
          retry_after = header(headers, "retry-after").to_f
          raise Slack::NotPosted.new("#{method}: rate limited (429, retry after #{retry_after.round}s)",
                                     code: "ratelimited", retry_after: retry_after)
        end
        raise Slack::Ambiguous.new("#{method}: HTTP #{status}; it may have posted", code: "http_#{status}") if status >= 500

        json = parse(body)
        raise Slack::Ambiguous.new("#{method}: HTTP #{status} with no Slack answer", code: "unreadable") unless json.is_a?(Hash)
        return json if json["ok"] == true

        error = json["error"].to_s.presence || "unknown_error"
        message = "#{method}: #{error}"
        raise Slack::NotPosted.new(message, code: error) if TRANSIENT_ERRORS.include?(error)
        raise Slack::Ambiguous.new(message, code: error) if AMBIGUOUS_ERRORS.include?(error)

        raise Slack::Refused.new(message, code: error)
      end

      def parse(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def header(headers, name)
        headers.find { |key, _| key.to_s.casecmp?(name) }&.last.then { |v| Array(v).first }
      end

      def http_post(method, params, token)
        uri = URI.join(API, method)
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{token}"
        # chat.* take a JSON body; read methods such as users.info take only
        # form arguments.
        if method.start_with?("chat.")
          request["Content-Type"] = "application/json; charset=utf-8"
          request.body = params.to_json
        else
          request.set_form_data(params.transform_values(&:to_s))
        end
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT,
                                                       read_timeout: READ_TIMEOUT, write_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end
        [ response.code.to_i, response.each_header.to_h, response.body ]
      end
    end
  end
end
