module DiscordDirectory
  # Mirrors each configured guild's channels and active threads into
  # discord_channels (docs/agents/system/report-destinations.md). Run by
  # DiscordChannelSyncJob every 15 minutes and by the Refresh channels button.
  #
  # The guilds are the ones config/agent_routes.yml lists under discord.guilds.
  # Per guild:
  #   1. GET /guilds/{id}/channels and /guilds/{id}/threads/active, through
  #      AgentMessages::DiscordBot;
  #   2. upsert every channel seen (unarchiving one that came back);
  #   3. archive every channel of that guild it no longer sees. Nothing is deleted.
  #
  # `postable` is the bot's real VIEW_CHANNEL + SEND_MESSAGES (SEND_MESSAGES_IN_THREADS
  # for a thread) from the guild's roles and the channel's overwrites
  # (DiscordDirectory::Permissions). When the roles or the bot's membership cannot
  # be read, it falls back to true for every message kind (text, announcement,
  # thread), and the summary says so.
  #
  # A guild whose channel list cannot be read is left exactly as it was. A guild
  # whose thread list cannot be read still syncs its channels, and archives no
  # thread.
  class Sync
    ROUTES_PATH = Rails.root.join("config/agent_routes.yml")

    # Discord's channel `type` numbers, to DiscordChannel::KINDS. A type not
    # listed (a directory, say) is not mirrored.
    KIND_BY_TYPE = {
      0 => "text", 5 => "announcement", 2 => "voice", 13 => "voice", 4 => "category",
      15 => "forum", 16 => "forum", 10 => "thread", 11 => "thread", 12 => "thread"
    }.freeze
    PRIVATE_THREAD = 12

    Summary = Struct.new(:guilds, :upserted, :archived, :errors, :notes, keyword_init: true) do
      def ok? = errors.empty?

      def to_s
        line = "#{guilds} guild(s), #{upserted} channel(s) seen, #{archived} archived"
        line += "; #{notes.join('; ')}" if notes.any?
        line += "; errors: #{errors.join('; ')}" if errors.any?
        line
      end
    end

    def self.guild_ids(path = ROUTES_PATH)
      config = YAML.safe_load_file(path, aliases: false) || {}
      (config.dig("discord", "guilds") || {}).keys.map(&:to_s)
    end

    def initialize(bot: AgentMessages::DiscordBot.new, guild_ids: self.class.guild_ids, clock: -> { Time.current })
      @bot = bot
      @guild_ids = guild_ids
      @clock = clock
    end

    def call
      summary = Summary.new(guilds: 0, upserted: 0, archived: 0, errors: [], notes: [])
      @guild_ids.each do |guild_id|
        sync_guild(guild_id, summary)
        summary.guilds += 1
      end
      summary
    end

    private

    def sync_guild(guild_id, summary)
      now = @clock.call
      channels = begin
        @bot.guild_channels(guild_id)
      rescue AgentMessages::DiscordBot::Error => e
        summary.errors << "guild #{guild_id}: #{e.message}"
        return
      end
      threads = begin
        @bot.active_threads(guild_id)
      rescue AgentMessages::DiscordBot::Error => e
        summary.errors << "guild #{guild_id} threads: #{e.message}"
        nil
      end
      permissions = permissions_for(guild_id, summary)

      by_id = channels.index_by { |c| c["id"].to_s }
      rows = channels.filter_map { |c| row(guild_id, c, by_id, permissions, now) }
      rows += Array(threads).filter_map { |t| row(guild_id, t, by_id, permissions, now) }

      DiscordChannel.transaction do
        DiscordChannel.upsert_all(rows, unique_by: %i[guild_external_id external_id]) if rows.any?
        stale = DiscordChannel.in_guild(guild_id).active.where.not(external_id: rows.map { |r| r[:external_id] })
        stale = stale.where.not(kind: "thread") if threads.nil?
        summary.archived += stale.update_all(archived_at: now, updated_at: now)
      end
      summary.upserted += rows.size
    end

    def row(guild_id, channel, by_id, permissions, now)
      kind = KIND_BY_TYPE[channel["type"].to_i]
      return nil unless kind

      parent = by_id[channel["parent_id"].to_s]
      {
        guild_external_id: guild_id.to_s,
        external_id: channel["id"].to_s,
        name: channel["name"].to_s.presence || channel["id"].to_s,
        kind: kind,
        parent_external_id: channel["parent_id"].presence&.to_s,
        category_name: category_name(kind, channel, parent, by_id),
        position: channel["position"],
        postable: postable?(kind, channel, parent, permissions),
        archived_at: nil,
        synced_at: now
      }
    end

    # A channel's category is its parent; a thread's is its parent channel's.
    def category_name(kind, channel, parent, by_id)
      return nil if kind == "category"
      return by_id[parent["parent_id"].to_s]&.dig("name") if kind == "thread" && parent
      return parent["name"] if parent

      nil
    end

    def postable?(kind, channel, parent, permissions)
      return false unless DiscordChannel::MESSAGE_KINDS.include?(kind)
      return false if kind == "thread" && channel.dig("thread_metadata", "locked")
      return true if permissions.nil? # roles unreadable: the documented fallback

      if kind == "thread"
        # A private thread is reachable only by its members; the active list does
        # not say whether the bot is one, so it is not offered.
        return false if channel["type"].to_i == PRIVATE_THREAD

        permissions.can_post?(parent&.dig("permission_overwrites"), thread: true)
      else
        permissions.can_post?(channel["permission_overwrites"])
      end
    end

    def permissions_for(guild_id, summary)
      @bot_user_id ||= @bot.current_user["id"].to_s
      member = @bot.guild_member(guild_id, @bot_user_id)
      Permissions.new(guild_id: guild_id, roles: @bot.guild_roles(guild_id),
                      member_role_ids: member["roles"], user_id: @bot_user_id)
    rescue AgentMessages::DiscordBot::Error => e
      summary.notes << "guild #{guild_id}: permissions unreadable (#{e.message[0, 120]}), every message channel marked postable"
      nil
    end
  end
end
