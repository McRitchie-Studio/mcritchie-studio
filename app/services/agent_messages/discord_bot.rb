require "net/http"
require "openssl"

module AgentMessages
  # The agents' Discord bot, over Discord's REST API: read a channel's new
  # messages, post one reply. No gateway connection, no websocket: the poll is
  # the deliberate v1 (docs/agents/system/agent-message-loop.md).
  #
  # The token is DISCORD_AGENT_BOT_TOKEN (1Password `agents.discord.xan`, field
  # `bot-token`). It is sent only in the Authorization header and never logged.
  #
  # `transport` is the one seam tests replace: a callable taking
  # (method, url, headers, body) and returning [status, body_string]. No test
  # reaches Discord.
  class DiscordBot
    API = "https://discord.com/api/v10".freeze
    TOKEN_ENV = "DISCORD_AGENT_BOT_TOKEN".freeze
    # Discord refuses message content over 2,000 characters (UTF-16 units).
    CONTENT_LIMIT = 2000
    PAGE_LIMIT = 100

    Error = Class.new(StandardError)
    class RateLimited < Error
      attr_reader :retry_after

      def initialize(retry_after)
        @retry_after = retry_after
        super("Discord rate-limited the bot; retry after #{retry_after}s")
      end
    end

    class_attribute :transport, default: nil

    def self.token = ENV[TOKEN_ENV].to_s.strip.presence
    def self.configured? = !token.nil?

    def initialize(token: self.class.token, transport: self.class.transport)
      raise Error, "#{TOKEN_ENV} is not set" if token.blank?

      @token = token
      @transport = transport || method(:net_http)
    end

    # The channel's messages newer than `after` (a message id), oldest first.
    # Discord returns a page newest-first; snowflakes sort as integers.
    def messages_after(channel_id, after: nil, limit: PAGE_LIMIT)
      query = { limit: limit }
      query[:after] = after if after.present?
      status, body = request(:get, "/channels/#{channel_id}/messages?#{query.to_query}")
      check!(status, body, "read channel #{channel_id}")
      Array(JSON.parse(body)).sort_by { |m| m["id"].to_i }
    end

    # Post `content` into `channel_id` as a reply to `reference_id`.
    #
    # `nonce` + `enforce_nonce` make the post idempotent: Discord answers a repeat
    # of the same nonce within a few minutes with the message it already created,
    # so a job retried after a timeout cannot post twice. `allowed_mentions` parses
    # nothing: an answer that quotes "@everyone" or a role from the untrusted
    # message never pings anyone but the author being replied to.
    def post_reply(channel_id, content:, reference_id:, nonce:)
      payload = {
        content: self.class.clip(content),
        message_reference: { message_id: reference_id.to_s, fail_if_not_exists: false },
        allowed_mentions: { parse: [], replied_user: true },
        nonce: nonce.to_s,
        enforce_nonce: true
      }
      status, body = request(:post, "/channels/#{channel_id}/messages", payload)
      check!(status, body, "post to channel #{channel_id}")
      JSON.parse(body)
    end

    # Post a standalone message (no reply reference) into `channel_id`: the floor
    # alert's ops notice. Same once-guard as a reply (nonce + enforce_nonce), and
    # it pings nobody: allowed_mentions parses nothing.
    def post_message(channel_id, content:, nonce:)
      payload = {
        content: self.class.clip(content),
        allowed_mentions: { parse: [] },
        nonce: nonce.to_s,
        enforce_nonce: true
      }
      status, body = request(:post, "/channels/#{channel_id}/messages", payload)
      check!(status, body, "post to channel #{channel_id}")
      JSON.parse(body)
    end

    def self.clip(text)
      text = text.to_s
      return text if ReleaseNotes::DiscordClient.discord_length(text) <= CONTENT_LIMIT

      out = +""
      text.each_char do |ch|
        break if ReleaseNotes::DiscordClient.discord_length(out + ch) > CONTENT_LIMIT - 1

        out << ch
      end
      out << "…"
    end

    private

    def request(method, path, body = nil)
      headers = { "Authorization" => "Bot #{@token}", "User-Agent" => "McRitchieStudio (https://mcritchie.studio, 1)" }
      headers["Content-Type"] = "application/json" if body
      @transport.call(method, "#{API}#{path}", headers, body && JSON.generate(body))
    end

    def check!(status, body, what)
      status = status.to_i
      return if status.between?(200, 299)

      if status == 429
        retry_after = (JSON.parse(body.to_s)["retry_after"] rescue nil)
        raise RateLimited, retry_after
      end
      raise Error, "Discord refused to #{what}: HTTP #{status} #{body.to_s[0, 300]}"
    end

    def net_http(method, url, headers, body)
      uri = URI(url)
      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |http| http.request(req) }
      [ res.code.to_i, res.body.to_s ]
    rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "Discord unreachable: #{e.class}"
    end
  end
end
