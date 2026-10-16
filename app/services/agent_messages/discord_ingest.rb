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
  # THE GATEWAY AND THE POLL RACE. Both can read "not stored yet" for one
  # message and both insert. The loser either fails the model's uniqueness
  # validation (RecordInvalid) or the unique index (RecordNotUnique), and gets
  # the winner's row back. The insert runs in its own SAVEPOINT
  # (requires_new), because the poll calls this inside its cursor transaction:
  # without one, the index violation aborts that whole transaction and the
  # re-read, the rest of the page and the cursor advance all fail.
  #
  # THE OWNER-ONLY GUARD. A routed message from a person
  # config/agent_answerers.yml does not allow (AgentMessages::Answerers) is
  # stored `held`, with a `held` event saying why, instead of `received`: kept
  # for the admin page, never claimed, until an admin releases it. The claim
  # enforces the same rule again on the server (AgentMessage.claimable).
  #
  # THE PERSON. Every stored row with an author resolves to an AgentPerson
  # (AgentMessage's create callback, AgentPerson.resolve!): the Discord user id
  # is the identity, created on first sight, never merged with another platform's.
  #
  # Returns the stored row, the existing row on a repeat, or nil for a message
  # that is not kept: anything a bot wrote (our own replies included), system
  # messages (joins, pins), a message from an unlisted guild or a muted
  # (`ignore: true`) channel, and an unaddressed message.
  class DiscordIngest
    INBOUND_TYPES = [ 0, 19 ].freeze # DEFAULT, REPLY
    REFERENCE_FORWARD = 1 # message_reference.type of a forward (0 is a reply)

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

    def initialize(routes:, router: Router.new(routes), answerers: Answerers.current, logger: Rails.logger)
      @routes = routes
      @router = router
      @answerers = answerers
      @logger = logger
    end

    # `parent_id` is a thread's parent channel (it carries the parent's override);
    # `source` names the reader on the timeline (discord-poll, discord-gateway).
    def call(raw, guild_id:, parent_id: nil, source: "discord-poll")
      return nil unless inbound?(raw)

      guild_id = guild_id.to_s
      return self.class.note_unlisted_guild(guild_id, logger: @logger) unless @routes.guild?(guild_id)
      return nil if @routes.ignored?(guild_id, raw["channel_id"], parent_id: parent_id)

      existing = AgentMessage.find_by(channel: "discord", external_id: raw["id"].to_s)
      return existing if existing

      store(raw, guild_id, parent_id, source)
    rescue ActiveRecord::RecordNotUnique
      AgentMessage.find_by(channel: "discord", external_id: raw["id"].to_s)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.is_a?(AgentMessage) && e.record.errors.of_kind?(:external_id, :taken)

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
      parent = referenced_row(raw, guild_id, channel_id)
      result = @router.route(guild_id: guild_id, channel_id: channel_id, parent_id: parent_id, content: raw["content"],
                             mention_users: users, mention_roles: roles)
      result = inherit_from(parent, result) if parent
      # Addressed-only: a routed soul, or a reply to a message we hold.
      return nil unless result.routed? || parent

      AgentMessage.transaction(requires_new: true) do
        author_ref = raw.dig("author", "id").to_s
        person = AgentPerson.resolve!(platform: "discord", external_id: author_ref, display_name: author_name(raw))
        held = result.routed? && !@answerers.allowed?(person)
        message = AgentMessage.create!(
          channel: "discord", external_id: raw["id"].to_s, guild_id: guild_id, channel_ref: channel_id,
          thread_key: parent&.thread_key || fresh_thread_key(raw, guild_id, channel_id, parent_id),
          author_ref: author_ref, author_name: author_name(raw), person: person,
          content: raw["content"].to_s, mentions: { "users" => users, "roles" => roles },
          soul_slug: result.soul, routed_by: result.routed_by,
          status: status_for(result, held), sent_at: parse_time(raw["timestamp"])
        )
        message.record!("received", actor: source, detail: { "author" => message.author_name })
        message.record!(result.routed? ? "routed" : "unrouted", actor: "router",
                        detail: result.detail.merge("soul" => result.soul, "routed_by" => result.routed_by).compact)
        if held
          message.record!("held", actor: "answerers",
                                  detail: { "reason" => "sender is not on config/agent_answerers.yml",
                                            "person_id" => person&.id }.compact)
        end
        message
      end
    end

    def status_for(result, held)
      return "unrouted" unless result.routed?

      held ? "held" : "received"
    end

    # A reply to a message we hold (or to an agent's reply to one) continues that
    # conversation: same thread, and the same soul when nothing names another.
    #
    # Only a reply IN THE SAME CHANNEL AND GUILD. A Discord forward (a type-0
    # message whose message_reference has type FORWARD and points into another
    # channel) and any reference naming another channel or guild are treated as
    # a fresh, unreferenced message: joining would hand it the referenced row's
    # thread, soul and ordering. The row lookup is pinned to this channel too,
    # so a reference that omits channel_id cannot reach across.
    def referenced_row(raw, guild_id, channel_id)
      reference = raw["message_reference"]
      return nil unless reference.is_a?(Hash)

      ref = reference["message_id"].to_s
      return nil if ref.empty? || reference["type"].to_i == REFERENCE_FORWARD
      return nil if reference["channel_id"].present? && reference["channel_id"].to_s != channel_id
      return nil if reference["guild_id"].present? && reference["guild_id"].to_s != guild_id

      AgentMessage.where(channel: "discord", guild_id: guild_id, channel_ref: channel_id)
                  .where("external_id = :ref OR reply_external_id = :ref", ref: ref).first
    end

    # A message that joins no held row starts its own thread, keyed by its own
    # id, EXCEPT inside a Discord thread channel: the whole thread channel is one
    # conversation, keyed by the thread's id (which is its starter message's id),
    # so every message in it shares the THREAD layer and is answered in order.
    # A thread channel is one the reader names a parent for, or one the channel
    # directory (DiscordChannel) lists as a thread.
    def fresh_thread_key(raw, guild_id, channel_id, parent_id)
      thread = parent_id.present? ||
               DiscordChannel.where(guild_external_id: guild_id, external_id: channel_id, kind: "thread").exists?
      "discord:#{channel_id}:#{thread ? channel_id : raw['id']}"
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
