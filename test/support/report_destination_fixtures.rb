# A fake Discord REST API for the channel directory and report delivery tests
# (docs/agents/system/report-destinations.md). It answers the DiscordBot calls by
# path and records every request. Ids are fake snowflakes; nothing reaches Discord.
module ReportDestinationFixtures
  GUILD = "920000000000000001".freeze
  BOT_USER = "920000000000000099".freeze
  BOT_ROLE = "920000000000000050".freeze
  CAT_OPS = "920000000000000010".freeze
  CAT_SECRET = "920000000000000011".freeze
  REPORTS = "920000000000000020".freeze      # text, under Ops
  NEWS = "920000000000000021".freeze         # announcement, under Ops
  LOCKED = "920000000000000022".freeze       # text, the bot is denied SEND_MESSAGES
  HIDDEN = "920000000000000023".freeze       # text, under a category; @everyone denied VIEW
  VOICE = "920000000000000024".freeze
  FORUM = "920000000000000025".freeze
  THREAD = "920000000000000030".freeze       # public thread in REPORTS

  VIEW = 1 << 10
  SEND = 1 << 11
  SEND_IN_THREADS = 1 << 38

  def discord_channels_payload(extra: [])
    [
      { "id" => CAT_OPS, "type" => 4, "name" => "Ops", "position" => 0, "permission_overwrites" => [] },
      { "id" => CAT_SECRET, "type" => 4, "name" => "Secret", "position" => 1, "permission_overwrites" => [] },
      { "id" => REPORTS, "type" => 0, "name" => "reports", "parent_id" => CAT_OPS, "position" => 0, "permission_overwrites" => [] },
      { "id" => NEWS, "type" => 5, "name" => "news", "parent_id" => CAT_OPS, "position" => 1, "permission_overwrites" => [] },
      { "id" => LOCKED, "type" => 0, "name" => "read-only", "parent_id" => CAT_OPS, "position" => 2,
        "permission_overwrites" => [ { "id" => BOT_ROLE, "type" => 0, "allow" => "0", "deny" => SEND.to_s } ] },
      { "id" => HIDDEN, "type" => 0, "name" => "hidden", "parent_id" => CAT_SECRET, "position" => 0,
        "permission_overwrites" => [ { "id" => GUILD, "type" => 0, "allow" => "0", "deny" => VIEW.to_s } ] },
      { "id" => VOICE, "type" => 2, "name" => "Lounge", "position" => 3, "permission_overwrites" => [] },
      { "id" => FORUM, "type" => 15, "name" => "ideas", "parent_id" => CAT_OPS, "position" => 4, "permission_overwrites" => [] }
    ] + extra
  end

  def discord_threads_payload(threads: nil)
    threads ||= [ { "id" => THREAD, "type" => 11, "name" => "weekly", "parent_id" => REPORTS,
                    "thread_metadata" => { "archived" => false, "locked" => false } } ]
    { "threads" => threads, "members" => [] }
  end

  def discord_roles_payload
    [ { "id" => GUILD, "name" => "@everyone", "permissions" => (VIEW | SEND | SEND_IN_THREADS).to_s },
      { "id" => BOT_ROLE, "name" => "Agents", "permissions" => "0" } ]
  end

  # A transport for AgentMessages::DiscordBot: (method, url, headers, body) ->
  # [status, body]. `overrides` maps a path suffix to [status, payload] to make
  # one call fail or answer differently. Every request lands in `requests`.
  class FakeDiscord
    attr_reader :requests
    attr_accessor :channels, :threads, :overrides

    def initialize(channels:, threads:, roles:, message_id: "920000000000000777")
      @channels = channels
      @threads = threads
      @roles = roles
      @message_id = message_id
      @overrides = {}
      @requests = []
      @nonces = {}
    end

    def posts = requests.select { |r| r[:method] == :post }

    def to_proc
      method(:call).to_proc
    end

    def call(method, url, headers, body)
      path = url.delete_prefix(AgentMessages::DiscordBot::API)
      parsed = body && JSON.parse(body)
      @requests << { method: method, path: path, auth: headers["Authorization"], body: parsed }
      override = @overrides.find { |suffix, _| path.end_with?(suffix) }&.last
      return [ override[0], JSON.generate(override[1]) ] if override

      case [ method, path ]
      in [ :get, "/users/@me" ] then ok("id" => BOT_USER, "username" => "xan", "bot" => true)
      in [ :get, %r{\A/guilds/\d+/channels\z} ] then ok(@channels)
      in [ :get, %r{\A/guilds/\d+/threads/active\z} ] then ok(@threads)
      in [ :get, %r{\A/guilds/\d+/roles\z} ] then ok(@roles)
      in [ :get, %r{\A/guilds/\d+/members/\d+\z} ] then ok("user" => { "id" => BOT_USER }, "roles" => [ BOT_ROLE ])
      in [ :post, %r{\A/channels/(\d+)/messages\z} ]
        # enforce_nonce: a repeated nonce gets the message it already made.
        id = (@nonces[parsed["nonce"]] ||= (@message_id.to_i + @nonces.size).to_s)
        ok("id" => id, "channel_id" => path[%r{/channels/(\d+)/}, 1])
      else [ 404, JSON.generate("message" => "Unknown route #{path}") ]
      end
    end

    private

    def ok(payload) = [ 200, JSON.generate(payload) ]
  end

  def fake_discord(**opts)
    FakeDiscord.new(channels: discord_channels_payload, threads: discord_threads_payload, roles: discord_roles_payload, **opts)
  end

  # DiscordBot's one network seam, swapped for the fake, with a token set.
  def with_fake_discord(fake)
    previous = AgentMessages::DiscordBot.transport
    AgentMessages::DiscordBot.transport = fake.to_proc
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") { yield fake }
  ensure
    AgentMessages::DiscordBot.transport = previous
  end

  def sync_fake!(fake)
    DiscordDirectory::Sync.new(bot: AgentMessages::DiscordBot.new(token: "test-token", transport: fake.to_proc),
                              guild_ids: [ GUILD ]).call
  end

  def channel!(external_id: REPORTS, name: "reports", kind: "text", postable: true, archived_at: nil, category_name: "Ops")
    DiscordChannel.create!(guild_external_id: GUILD, external_id: external_id, name: name, kind: kind,
                           postable: postable, archived_at: archived_at, category_name: category_name, synced_at: Time.current)
  end
end
