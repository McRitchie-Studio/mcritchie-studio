module AgentMessages
  # Stores ONE Bot Framework activity from Microsoft Teams as an AgentMessage,
  # once (docs/agents/system/agent-message-loop.md, "Teams"). Called by
  # TeamsIngestJob with the activity Webhooks::TeamsMessagesController verified.
  #
  # THE ROW. channel "teams", external_id "<channel>:<activity id>" (unique per
  # channel and id), guild_id the tenant id, channel_ref the conversation's
  # base id (a channel's 19:…@thread.tacv2, never with ;messageid=; a chat's
  # own id), thread_key "teams:<channel>:<root id>" (a channel thread is one
  # conversation, keyed by its root: the ;messageid= of conversation.id), and
  # envelope the reference a reply needs: service_url, conversation_id (the
  # full id, thread included), activity_id, from_id, conversation_type
  # ("personal" for a chat with the bot: MemoryBundle#private_channel?),
  # tenant_id, team_id.
  #
  # ONCE. The unique index on (channel, external_id) is the guard: the Bot
  # Framework retries a delivery it got no quick answer for. The loser of a
  # race gets the winner's row back, as in SlackIngest.
  #
  # WHAT IS NEVER STORED: another tenant's activity (with no tenant configured,
  # nothing is read); anything a bot wrote (from.id 28:…, from.role bot, or our
  # own bot: Teams delivers no bot's messages even under RSC, and this checks
  # anyway); every activity but `message` (edits, deletes and reactions are
  # other types); a message with no text; a muted channel; an unaddressed one.
  #
  # ROUTING, CLEARANCE, THE OWNER-ONLY GUARD and FAN-OUT are Slack's, shared
  # (AgentMessages::ChatIngest, AgentMessages::ChannelRoutes, the `teams:`
  # block): names at the start of the text, everyone, the thread's soul, the
  # mention soul for an @mention of the bot or a personal chat, the channel's
  # default soul. The bot's own <at>…</at> mention is stripped from the text
  # first (as Microsoft's channel-and-group-conversations page says to), so
  # "@McRitchie Agents Avi, …" is read as "Avi, …". The person is the Entra
  # object id (from.aadObjectId, AgentPerson.resolve!, platform "teams");
  # Alex McRitchie's is teams.owner_aad_object_id (AgentPerson.seed_owner!).
  #
  # CONVERSATION REFERENCES. A conversationUpdate that adds the bot (the install
  # into a team or chat), an installationUpdate, a channelCreated event, and
  # every message the bot reads record where it may post (TeamsConversation).
  class TeamsIngest
    CHANNEL = "teams".freeze
    RECEIVED_ACTOR = "teams-events".freeze
    REFERENCE_TYPES = %w[conversationUpdate installationUpdate].freeze

    include ChatIngest

    def initialize(routes: TeamsRoutes.current, answerers: Answerers.current, logger: Rails.logger)
      @routes = routes
      @answerers = answerers
      @logger = logger
    end

    # The stored row, the existing row on a repeat, a TeamsConversation for an
    # install event, or nil when the activity is not kept.
    def call(activity)
      activity = activity.to_h.deep_stringify_keys
      return nil unless activity["channelId"] == "msteams"
      return note_other_tenant(tenant_of(activity)) unless @routes.tenant?(tenant_of(activity))
      return remember_install(activity) if REFERENCE_TYPES.include?(activity["type"])
      return nil unless inbound?(activity)

      event = normalize(activity)
      return nil if event["text"].blank? || @routes.ignored?(event["channel"])

      remember!(activity, event["channel"], status: "installed")
      external_id = "#{event['channel']}:#{event['ts']}"
      existing = AgentMessage.find_by(channel: CHANNEL, external_id: external_id)
      return existing if existing

      store(event, external_id, { activity: activity })
    rescue ActiveRecord::RecordNotUnique
      AgentMessage.find_by(channel: CHANNEL, external_id: external_id)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.is_a?(AgentMessage) && e.record.errors.of_kind?(:external_id, :taken)

      AgentMessage.find_by(channel: CHANNEL, external_id: external_id)
    end

    # The activity in ChatIngest's normalized shape (its comment): the channel's
    # base id, the activity id, the thread root, the cleaned text, the author's
    # Entra object id; plus what this class reads back ("user_name",
    # "mentioned_bot", "conversation_type").
    def normalize(activity)
      conversation = activity["conversation"] || {}
      base, root = conversation["id"].to_s.split(";messageid=", 2)
      {
        "channel" => base.to_s, "ts" => activity["id"].to_s, "thread_ts" => root.presence,
        "text" => clean_text(activity), "user" => activity.dig("from", "aadObjectId").to_s,
        "user_name" => activity.dig("from", "name").to_s,
        "mentioned_bot" => bot_mentioned?(activity), "conversation_type" => conversation["conversationType"].to_s
      }
    end

    private

    def inbound?(activity)
      return false unless activity["type"] == "message"

      from = activity["from"] || {}
      return false if activity["id"].blank? || activity.dig("conversation", "id").blank? || from["aadObjectId"].blank?
      return false if from["role"].to_s.casecmp?("bot") || from["id"].to_s.start_with?("28:") || @routes.bot?(from["id"])

      true
    end

    def tenant_of(activity) = activity.dig("channelData", "tenant", "id").presence || activity.dig("conversation", "tenantId")

    # The text as the router reads it: the bot's own mention removed (each
    # mention entity whose mentioned.id is the bot, by its exact entity text),
    # another <at>Name</at> kept as "@Name", and any HTML a formatted message
    # carries reduced to its text.
    def clean_text(activity)
      text = activity["text"].to_s
      mention_entities(activity).each do |entity|
        markup = entity["text"].to_s
        next if markup.empty?

        if @routes.bot?(entity.dig("mentioned", "id"))
          text = text.gsub(markup, " ")
        else
          text = text.gsub(markup, "@#{markup.gsub(%r{</?at>}i, '').delete_prefix('@')}")
        end
      end
      text = text.gsub(%r{<at>(.*?)</at>}i) { "@#{Regexp.last_match(1).delete_prefix('@')}" }
      if text.include?("<")
        text = text.gsub(%r{<br\s*/?>|</p>|</div>}i, "\n")
        text = CGI.unescapeHTML(Rails::HTML5::FullSanitizer.new.sanitize(text).to_s)
      end
      text.gsub(/[ \t]+/, " ").gsub(/ *\n */, "\n").strip
    end

    def mention_entities(activity)
      Array(activity["entities"]).select { |e| e.is_a?(Hash) && e["type"] == "mention" }
    end

    def bot_mentioned?(activity) = mention_entities(activity).any? { |e| @routes.bot?(e.dig("mentioned", "id")) }

    # ChatIngest's hooks.
    def mention_reason(event, _text)
      return "direct message" if event["conversation_type"] == "personal"

      "app mention" if event["mentioned_bot"]
    end

    def thread_key(event) = "teams:#{event['channel']}:#{event['thread_ts'].presence || event['ts']}"

    # A fan-out sibling: "<channel>:<soul>:<activity id>", the id still last.
    def sibling_id(event, soul) = "#{event['channel']}:#{soul}:#{event['ts']}"

    def display_name(event) = event["user_name"].to_s.strip.presence || "teams #{event['user'].to_s[0, 8]}"

    def row_attributes(event, ctx)
      activity = ctx[:activity]
      others = mention_entities(activity).filter_map { |e| e.dig("mentioned", "id").presence unless @routes.bot?(e.dig("mentioned", "id")) }
      {
        guild_id: tenant_of(activity).to_s, channel_ref: event["channel"],
        mentions: { "users" => others.uniq }, sent_at: sent_at(activity),
        envelope: {
          "conversation_type" => event["conversation_type"].presence, "service_url" => activity["serviceUrl"].to_s,
          "conversation_id" => activity.dig("conversation", "id").to_s, "activity_id" => activity["id"].to_s,
          "from_id" => activity.dig("from", "id").presence, "tenant_id" => tenant_of(activity).presence,
          "team_id" => activity.dig("channelData", "team", "id").presence, "thread_root" => event["thread_ts"],
          AgentMessage::FAN_KEY => ctx[:fan]
        }.compact
      }
    end

    def sent_at(activity)
      Time.zone.parse(activity["timestamp"].to_s) || Time.current
    rescue ArgumentError
      Time.current
    end

    # The install and its relatives: the bot added to a team or chat
    # (conversationUpdate with the bot in membersAdded; installationUpdate
    # add), removed (membersRemoved; installationUpdate remove), or a channel
    # created in a team where it is installed (channelCreated). Answers the
    # TeamsConversation written, or nil.
    def remember_install(activity)
      base = activity.dig("conversation", "id").to_s.split(";messageid=").first.to_s
      return nil if base.empty? || activity["serviceUrl"].blank?

      added = Array(activity["membersAdded"]).any? { |m| bot_member?(activity, m) }
      removed = Array(activity["membersRemoved"]).any? { |m| bot_member?(activity, m) }
      action = activity["action"].to_s
      event = activity.dig("channelData", "eventType").to_s

      if event == "channelCreated" && (created = activity.dig("channelData", "channel", "id")).present?
        return remember!(activity, created, status: "installed", name: activity.dig("channelData", "channel", "name"),
                                            conversation_type: "channel")
      end
      return remember!(activity, base, status: "removed") if removed || action.start_with?("remove")
      return remember!(activity, base, status: "installed", installed_by: true) if added || action.start_with?("add")

      nil
    end

    def bot_member?(activity, member)
      id = (member || {})["id"].to_s
      id.present? && (id == activity.dig("recipient", "id").to_s || @routes.bot?(id))
    end

    def remember!(activity, conversation_id, status:, name: nil, conversation_type: nil, installed_by: false)
      TeamsConversation.remember!(
        conversation_id: conversation_id, service_url: activity["serviceUrl"], status: status,
        conversation_type: conversation_type || activity.dig("conversation", "conversationType"),
        tenant_id: tenant_of(activity), team_id: activity.dig("channelData", "team", "id"),
        team_name: activity.dig("channelData", "team", "name"),
        name: name || activity.dig("channelData", "channel", "name") || activity.dig("conversation", "name"),
        bot_id: activity.dig("recipient", "id"),
        installed_by_aad_object_id: (activity.dig("from", "aadObjectId") if installed_by)
      )
    end

    def note_other_tenant(tenant_id)
      @logger.info("[agent-messages] ignoring Teams tenant #{tenant_id.to_s[0, 40]}: not config/agent_routes.yml teams.tenant_id")
      nil
    end
  end
end
