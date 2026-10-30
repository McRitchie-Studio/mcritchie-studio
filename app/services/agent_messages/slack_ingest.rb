module AgentMessages
  # Stores ONE Slack Events API event as an AgentMessage, once
  # (docs/agents/system/agent-message-loop.md, "Slack"). Called by SlackIngestJob
  # with the event hash and the payload's team_id.
  #
  # THE ROW. channel "slack", external_id "<channel id>:<ts>" (a ts is unique
  # only within its channel), guild_id the team id, channel_ref the channel id,
  # thread_key "slack:<channel>:<thread_ts || ts>" (a Slack thread is one
  # conversation, keyed by its root), and envelope.channel_type ("im" for a DM:
  # MemoryBundle#private_channel?).
  #
  # ONCE. The unique index on (channel, external_id) is the guard: Slack retries
  # an event it got no quick 200 for, and a message that mentions the app comes
  # twice (message.channels and app_mention, the same ts). The loser of a race
  # gets the winner's row back, as in DiscordIngest.
  #
  # WHAT IS NEVER STORED: an event from another workspace; anything a bot wrote
  # (bot_id, subtype bot_message, or the app's own bot user: our customized posts
  # come back as events, as do the Steffon Admin app's); edits, deletes, joins
  # and every other subtype; a muted channel; an unaddressed message.
  #
  # ROUTING (AgentMessages::SlackRoutes): a soul NAMED at the start of the text,
  # else the soul of the thread it replies in, else the app's mention soul for
  # an @-mention or a DM, else the channel's default soul. A reply in a thread
  # the mailbox holds whose thread has no soul is kept `unrouted`, as on Discord.
  #
  # CLEARANCE (SlackRoutes#cleared?): a channel may name the souls cleared to
  # answer in it (`souls:` plus the block's core_souls) or admit all (`open:
  # true`). A message routed, by any rule, to a soul not cleared there is stored
  # `held` with the reason on its `held` event, and never answered unless an
  # admin releases it. A channel with no clearance config admits every soul.
  #
  # THE OWNER-ONLY GUARD and THE PERSON are DiscordIngest's: the Slack user id is
  # the identity (AgentPerson.resolve!, platform "slack"); a routed message from
  # a role config/agent_answerers.yml does not answer is stored `held`. Alex
  # McRitchie's user id is linked to the owner (AgentPerson.seed_owner!).
  class SlackIngest
    CHANNEL = "slack".freeze
    # Subtypes that are still a person's new message.
    MESSAGE_SUBTYPES = [ nil, "", "file_share", "thread_broadcast" ].freeze
    EVENT_TYPES = %w[message app_mention].freeze

    def initialize(routes: SlackRoutes.current, answerers: Answerers.current, client: nil, logger: Rails.logger)
      @routes = routes
      @answerers = answerers
      @client = client
      @logger = logger
    end

    # The stored row, the existing row on a repeat, or nil when the event is
    # not kept.
    def call(event, team_id:, event_id: nil)
      event = event.to_h.deep_stringify_keys
      return nil unless inbound?(event)
      return note_other_team(team_id) unless @routes.team?(team_id)
      return nil if @routes.ignored?(event["channel"])

      external_id = "#{event['channel']}:#{event['ts']}"
      existing = AgentMessage.find_by(channel: CHANNEL, external_id: external_id)
      return existing if existing

      store(event, team_id.to_s, external_id, event_id)
    rescue ActiveRecord::RecordNotUnique
      AgentMessage.find_by(channel: CHANNEL, external_id: external_id)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.is_a?(AgentMessage) && e.record.errors.of_kind?(:external_id, :taken)

      AgentMessage.find_by(channel: CHANNEL, external_id: external_id)
    end

    # The routing decision alone (pure but for the thread lookup), for tests and
    # for the timeline's `routed` event.
    def route(event)
      text = event["text"].to_s
      named = @routes.named(text)
      return Router::Result.new(soul: named, routed_by: "name", detail: { "matched" => "name" }) if named

      parent = thread_row(event)
      if parent&.soul_slug.present?
        return Router::Result.new(soul: parent.soul_slug, routed_by: "thread", detail: { "matched" => "thread of message #{parent.id}" })
      end

      if (@routes.mentions_bot?(text) || event["type"] == "app_mention" || im?(event)) && @routes.mention_soul
        why = im?(event) ? "direct message" : "app mention"
        return Router::Result.new(soul: @routes.mention_soul, routed_by: "mention", detail: { "matched" => why })
      end

      default = @routes.default_soul(event["channel"])
      return Router::Result.new(soul: default, routed_by: "default", detail: { "matched" => "channel default" }) if default

      Router::Result.new(soul: nil, routed_by: "none", detail: { "reason" => "no soul named, no thread, no mention and no channel default" })
    end

    private

    def inbound?(event)
      return false unless EVENT_TYPES.include?(event["type"])
      return false unless MESSAGE_SUBTYPES.include?(event["subtype"])
      return false if event["bot_id"].present? || event["bot_profile"].present?
      return false if event["user"].blank? || event["channel"].blank? || event["ts"].blank?
      return false if @routes.bot_user_id.present? && event["user"] == @routes.bot_user_id

      true
    end

    def store(event, team_id, external_id, event_id)
      result = route(event)
      parent = result.routed_by == "thread" ? nil : thread_row(event)
      return nil unless result.routed? || parent

      author_ref = event["user"].to_s
      name = author_name(author_ref)
      AgentMessage.transaction(requires_new: true) do
        person = AgentPerson.resolve!(platform: CHANNEL, external_id: author_ref, display_name: name)
        uncleared = result.routed? && !@routes.cleared?(event["channel"], result.soul)
        unanswered = result.routed? && !@answerers.allowed?(person)
        held = uncleared || unanswered
        message = AgentMessage.create!(
          channel: CHANNEL, external_id: external_id, guild_id: team_id, channel_ref: event["channel"].to_s,
          thread_key: thread_key(event), author_ref: author_ref, author_name: name, person: person,
          content: event["text"].to_s, mentions: { "users" => mentioned_users(event["text"]) },
          soul_slug: result.soul, routed_by: result.routed_by, status: status_for(result, held),
          sent_at: Time.zone.at(event["ts"].to_f),
          envelope: { "channel_type" => channel_type(event), "event_id" => event_id.presence,
                      "thread_ts" => event["thread_ts"].presence }.compact
        )
        message.record!("received", actor: "slack-events", detail: { "author" => message.author_name })
        message.record!(result.routed? ? "routed" : "unrouted", actor: "router",
                        detail: result.detail.merge("soul" => result.soul, "routed_by" => result.routed_by).compact)
        record_held(message, event, result, person, uncleared: uncleared, unanswered: unanswered) if held
        message
      end
    end

    # One `held` event naming every cause: the channel's clearance (the soul may
    # not answer here) and/or the owner-only guard (the sender is not answered).
    def record_held(message, event, result, person, uncleared:, unanswered:)
      reasons = []
      reasons << @routes.clearance_reason(event["channel"], result.soul) if uncleared
      reasons << @answerers.held_reason(person) if unanswered
      actor = uncleared ? "slack-clearance" : "answerers"
      detail = { "reason" => reasons.join("; "), "person_id" => person&.id }
      detail["cleared"] = @routes.cleared_souls(event["channel"]) if uncleared
      message.record!("held", actor: actor, detail: detail.compact)
    end

    def thread_key(event) = "slack:#{event['channel']}:#{event['thread_ts'].presence || event['ts']}"

    # The oldest row the mailbox holds in this message's thread (a reply in a
    # thread only: thread_ts set and not the message itself), or nil.
    def thread_row(event)
      return nil if event["thread_ts"].blank? || event["thread_ts"] == event["ts"]

      AgentMessage.where(channel: CHANNEL, channel_ref: event["channel"].to_s, thread_key: thread_key(event))
                  .order(Arel.sql("soul_slug IS NULL"), :id).first
    end

    def status_for(result, held)
      return "unrouted" unless result.routed?

      held ? "held" : "received"
    end

    # app_mention events carry no channel_type; a DM's channel id starts with D.
    def channel_type(event) = event["channel_type"].presence || (event["channel"].to_s.start_with?("D") ? "im" : "channel")

    def im?(event) = channel_type(event) == "im"

    def mentioned_users(text) = text.to_s.scan(/<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/).flatten.uniq

    # The sender's Slack display name (users.info, best effort), else their id.
    def author_name(user_id)
      client = @client || Media::Slack::Client.new
      (client.configured? && client.user_name(user_id)).presence || "slack #{user_id}"
    rescue StandardError
      "slack #{user_id}"
    end

    def note_other_team(team_id)
      @logger.info("[agent-messages] ignoring Slack team #{team_id.to_s[0, 20]}: not config/agent_routes.yml slack.team_id")
      nil
    end
  end
end
