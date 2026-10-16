require "net/http"
require "openssl"

module AgentMessages
  # The agents' Discord bot, over Discord's REST API: list a guild's channels and
  # active threads, read a channel's new messages, post one reply. The push half
  # (the Gateway websocket) is AgentMessages::DiscordGateway; this REST client is
  # the backstop poll's reader and the only writer
  # (docs/agents/system/agent-message-loop.md).
  #
  # The token is DISCORD_AGENT_BOT_TOKEN (1Password `agents.discord.xan`, field
  # `bot-token`): the SHARED bot, the one reader and the default writer. A soul
  # with its own Discord app replies through it instead when
  # DISCORD_BOT_TOKEN_<SOUL> is set (`soul_token`, e.g. DISCORD_BOT_TOKEN_AVI,
  # DISCORD_BOT_TOKEN_TURF_MONSTER, DISCORD_BOT_TOKEN_TYRION). A token is sent
  # only in the Authorization header: never logged, never in an exception
  # message, and `inspect` redacts it.
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

    # The per-soul reply token's ENV prefix; the soul slug, upcased, completes it.
    SOUL_TOKEN_PREFIX = "DISCORD_BOT_TOKEN_".freeze

    Error = Class.new(StandardError)
    # 401 or 403: a bad token, a bot not in the guild, or a missing channel
    # permission. Retrying the same bot cannot help.
    Unauthorized = Class.new(Error)
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

    # The ENV name holding `soul`'s own bot token: DISCORD_BOT_TOKEN_TURF_MONSTER
    # for turf_monster. Only letters, digits and underscores survive.
    def self.soul_token_env(soul)
      "#{SOUL_TOKEN_PREFIX}#{soul.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')}"
    end

    # `soul`'s own bot token, or nil when its var is absent or blank.
    def self.soul_token(soul)
      return nil if soul.blank?

      ENV[soul_token_env(soul)].to_s.strip.presence
    end

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

    # Every channel of a guild (GET /guilds/{id}/channels): text, voice, forum,
    # category alike; the caller picks the kinds it reads.
    def guild_channels(guild_id)
      status, body = request(:get, "/guilds/#{guild_id}/channels")
      check!(status, body, "list channels of guild #{guild_id}")
      Array(JSON.parse(body))
    end

    # The guild's active (unarchived) threads, forum posts included
    # (GET /guilds/{id}/threads/active). Each carries its `parent_id`.
    def active_threads(guild_id)
      status, body = request(:get, "/guilds/#{guild_id}/threads/active")
      check!(status, body, "list active threads of guild #{guild_id}")
      Array(JSON.parse(body)["threads"])
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

    # Show the bot as typing in `channel_id` (POST /channels/{id}/typing, 204, no
    # body). Discord shows the indicator for about ten seconds, or until the bot
    # posts a message there, so a caller that wants it held re-sends it; the
    # agent mailbox does that every few seconds while an answer runs
    # (AgentMessageTypingJob). Raises like every call here: Unauthorized on
    # 401/403, RateLimited on 429.
    def trigger_typing(channel_id)
      status, body = request(:post, "/channels/#{channel_id}/typing")
      check!(status, body, "show typing in channel #{channel_id}")
      true
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

    # ── The report-destination reads and post (docs/agents/system/report-destinations.md).
    # DiscordDirectory::Sync reads the bot's own user, the guild's roles and the
    # bot's membership to work out where it may post; ReportDestinations posts.

    # The bot's own user (GET /users/@me): its id names its guild membership.
    def current_user
      status, body = request(:get, "/users/@me")
      check!(status, body, "read the bot's own user")
      JSON.parse(body)
    end

    # The guild's roles with their permission bitsets (GET /guilds/{id}/roles).
    def guild_roles(guild_id)
      status, body = request(:get, "/guilds/#{guild_id}/roles")
      check!(status, body, "list roles of guild #{guild_id}")
      Array(JSON.parse(body))
    end

    # One member of the guild, with their role ids (GET /guilds/{id}/members/{user}).
    def guild_member(guild_id, user_id)
      status, body = request(:get, "/guilds/#{guild_id}/members/#{user_id}")
      check!(status, body, "read member #{user_id} of guild #{guild_id}")
      JSON.parse(body)
    end

    # A report: `content` and up to ten `embeds`, posted as one standalone
    # message. The same once-guard as a reply (nonce + enforce_nonce), and it
    # pings nobody. It does NOT clip: ReportDestinations refuses an over-limit
    # report before it gets here, so a report is never silently cut.
    def post_report(channel_id, content:, embeds:, nonce:)
      payload = { allowed_mentions: { parse: [] }, nonce: nonce.to_s, enforce_nonce: true }
      payload[:content] = content.to_s if content.present?
      payload[:embeds] = embeds if embeds.present?
      status, body = request(:post, "/channels/#{channel_id}/messages", payload)
      check!(status, body, "post a report to channel #{channel_id}")
      JSON.parse(body)
    end

    # Never print the token: a bot in a log line, an error report or a console
    # shows its class and nothing else.
    def inspect = "#<#{self.class.name} token=[REDACTED]>"

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
      detail = "Discord refused to #{what}: HTTP #{status} #{redact(body.to_s)[0, 300]}"
      raise Unauthorized, detail if [ 401, 403 ].include?(status)

      raise Error, detail
    end

    # Belt and braces: Discord's error bodies do not echo the token, but nothing
    # this class raises may carry it even if one did.
    def redact(text) = @token.present? ? text.gsub(@token, "[REDACTED]") : text

    def net_http(method, url, headers, body)
      uri = URI(url)
      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(uri)
      headers.each { |k, v| req[k] = v }
      # A POST with no payload (typing) still says Content-Length: 0.
      req.body = body || "" if body || method == :post
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |http| http.request(req) }
      [ res.code.to_i, res.body.to_s ]
    rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "Discord unreachable: #{e.class}"
    end
  end
end
