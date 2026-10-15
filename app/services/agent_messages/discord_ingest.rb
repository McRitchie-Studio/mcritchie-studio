module AgentMessages
  # Stores ONE Discord message as an AgentMessage, once. The unique index on
  # (channel, external_id) is the guard, so a re-read page (a poll that died
  # before advancing its cursor, two polls overlapping) or the gateway and the
  # backstop poll seeing the same message inserts nothing new.
  #
  # ONLY ADDRESSED MESSAGES ARE KEPT. The whole of every listed guild is in
  # scope, so storing everything would hoard everyone's chatter. A message is
  # stored when it mentions a routed soul (user or role), replies to a message
  # the mailbox holds (or to an agent's reply to one), or sits in a channel whose
  # override sets `default_soul`. Anything else is dropped unstored.
  #
  # Returns the stored row, the existing row on a repeat, or nil for a message
  # that is not kept: anything a bot wrote (our own replies included), system
  # messages (joins, pins), a message from an unlisted guild or a muted
  # (`ignore: true`) channel, and an unaddressed message.
  class DiscordIngest
    INBOUND_TYPES = [ 0, 19 ].freeze # DEFAULT, REPLY

    # Unlisted guilds already named in the log, per process: the line is said once.
    @unlisted_guilds = Set.new
    @unlisted_lock = Mutex.new

    class << self
      # Logs once per process that a guild the bot sits in is not in
      # config/agent_routes.yml, so its messages are ignored. Returns nil.
      def note_unlisted_guild(guild_id, logger: Rails.logger)
        first = @unlisted_lock.synchronize { @unlisted_guilds.add?(guild_id.to_s) }
        logger.info("[agent-messages] ignoring Discord guild #{guild_id}: not listed in config/agent_routes.yml") if first
        nil
      end

      def reset_unlisted_guilds! = @unlisted_lock.synchronize { @unlisted_guilds.clear }
    end

    def initialize(routes:, router: Router.new(routes))
      @routes = routes
      @router = router
    end

    # `parent_id` is a thread's parent channel (it carries the parent's override);
    # `source` names the reader on the timeline (discord-poll, discord-gateway).
    def call(raw, guild_id:, parent_id: nil, source: "discord-poll")
      return nil unless inbound?(raw)

      guild_id = guild_id.to_s
      return self.class.note_unlisted_guild(guild_id) unless @routes.guild?(guild_id)
      return nil if @routes.ignored?(guild_id, raw["channel_id"], parent_id: parent_id)

      existing = AgentMessage.find_by(channel: "discord", external_id: raw["id"].to_s)
      return existing if existing

      store(raw, guild_id, parent_id, source)
    rescue ActiveRecord::RecordNotUnique
      AgentMessage.find_by(channel: "discord", external_id: raw["id"].to_s)
    end

    private

    def inbound?(raw)
      author = raw["author"] || {}
      return false if author["bot"] || raw["webhook_id"].present?
      return false if @routes.bot_user_id.present? && author["id"].to_s == @routes.bot_user_id

      INBOUND_TYPES.include?(raw["type"].to_i)
    end

    def store(raw, guild_id, parent_id, source)
      channel_id = raw["channel_id"].to_s
      users = Array(raw["mentions"]).map { |u| u["id"].to_s }
      roles = Array(raw["mention_roles"]).map(&:to_s)
      parent = referenced_row(raw)
      result = @router.route(guild_id: guild_id, channel_id: channel_id, parent_id: parent_id, content: raw["content"],
                             mention_users: users, mention_roles: roles)
      result = inherit_from(parent, result) if parent
      # Addressed-only: a routed soul, or a reply to a message we hold.
      return nil unless result.routed? || parent

      AgentMessage.transaction do
        message = AgentMessage.create!(
          channel: "discord", external_id: raw["id"].to_s, guild_id: guild_id, channel_ref: channel_id,
          thread_key: parent&.thread_key || "discord:#{channel_id}:#{raw['id']}",
          author_ref: raw.dig("author", "id").to_s, author_name: author_name(raw),
          content: raw["content"].to_s, mentions: { "users" => users, "roles" => roles },
          soul_slug: result.soul, routed_by: result.routed_by,
          status: result.routed? ? "received" : "unrouted", sent_at: parse_time(raw["timestamp"])
        )
        message.record!("received", actor: source, detail: { "author" => message.author_name })
        message.record!(result.routed? ? "routed" : "unrouted", actor: "router",
                        detail: result.detail.merge("soul" => result.soul, "routed_by" => result.routed_by).compact)
        message
      end
    end

    # A reply to a message we hold (or to an agent's reply to one) continues that
    # conversation: same thread, and the same soul when nothing names another.
    def referenced_row(raw)
      ref = raw.dig("message_reference", "message_id").to_s
      return nil if ref.empty?

      AgentMessage.where(channel: "discord").where("external_id = :ref OR reply_external_id = :ref", ref: ref).first
    end

    def inherit_from(parent, result)
      return result if result.routed_by.in?(%w[user role]) || parent.soul_slug.blank?

      Router::Result.new(soul: parent.soul_slug, routed_by: "thread",
                         detail: { "matched" => "reply to message #{parent.id}" })
    end

    def author_name(raw)
      author = raw["author"] || {}
      raw.dig("member", "nick").presence || author["global_name"].presence || author["username"].to_s
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
