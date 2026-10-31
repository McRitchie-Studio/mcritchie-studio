module AgentMessages
  # The medium-neutral half of a threaded chat medium's ingest (SlackIngest,
  # TeamsIngest): ROUTING (name, several names, everyone, thread, mention,
  # channel default), CLEARANCE and the owner-only guard per soul, and FAN-OUT
  # (one row per soul named, in one transaction, all in the message's thread)
  # (docs/agents/system/agent-message-loop.md, "Slack" and "Teams").
  #
  # It reads a NORMALIZED event Hash, the shape Slack's events already have:
  #   "channel"    the channel (or chat) the message is in: channel_ref
  #   "ts"         the message's own id in that channel
  #   "thread_ts"  the id of the thread's root message (blank or == ts for a root)
  #   "text"       what the person wrote, as the router should read it
  #   "user"       the author's id on the medium: author_ref, the person's identity
  # Teams' activities are normalized to it (TeamsIngest#normalize).
  #
  # The including class supplies @routes (a ChannelRoutes), @answerers, CHANNEL,
  # RECEIVED_ACTOR, and these hooks:
  #   mention_reason(event, text)  "app mention" / "direct message" when the
  #                                message is to the bot itself, else nil
  #   thread_key(event)            the row's thread_key
  #   sibling_id(event, soul)      a fan-out sibling's external_id
  #   display_name(event)          the author's name
  #   row_attributes(event, ctx)   the medium's own columns (guild_id,
  #                                channel_ref, mentions, sent_at, envelope)
  module ChatIngest
    # The routing decision alone (pure but for the thread lookup), for tests and
    # for the timeline's `routed` event.
    def route(event) = routes_for(event).first

    # Every routing decision for the event: one Router::Result per soul it is
    # for, the first being the primary row's. Several only when the text opens
    # by addressing several souls by name, or everyone.
    def routes_for(event)
      text = event["text"].to_s
      if @routes.everyone?(text)
        souls = @routes.everyone_in(event["channel"])
        left_out = @routes.routed_souls - souls
        detail = { "matched" => "everyone", "fan" => souls.presence, "not_cleared" => left_out.presence }.compact
        return souls.map { |soul| Router::Result.new(soul: soul, routed_by: "name", detail: detail) } if souls.any?
      end

      named = @routes.addressed(text)
      if named.any?
        detail = { "matched" => "name", "fan" => (named if named.length > 1) }.compact
        return named.map { |soul| Router::Result.new(soul: soul, routed_by: "name", detail: detail) }
      end

      [ single_route(event, text) ]
    end

    private

    def single_route(event, text)
      parent = thread_row(event)
      if parent&.soul_slug.present?
        return Router::Result.new(soul: parent.soul_slug, routed_by: "thread", detail: { "matched" => "thread of message #{parent.id}" })
      end

      if (why = mention_reason(event, text)) && @routes.mention_soul
        return Router::Result.new(soul: @routes.mention_soul, routed_by: "mention", detail: { "matched" => why })
      end

      default = @routes.default_soul(event["channel"])
      return Router::Result.new(soul: default, routed_by: "default", detail: { "matched" => "channel default" }) if default

      Router::Result.new(soul: nil, routed_by: "none", detail: { "reason" => "no soul named, no thread, no mention and no channel default" })
    end

    # Stores the event once per soul it is for, in one transaction; answers the
    # primary row, or nil when it is for nobody and replies in no held thread.
    # `ctx` is handed to #row_attributes untouched.
    def store(event, external_id, ctx)
      results = routes_for(event)
      primary = results.first
      parent = primary.routed_by == "thread" ? nil : thread_row(event)
      return nil unless primary.routed? || parent

      author_ref = event["user"].to_s
      name = display_name(event)
      fan = results.length > 1 ? external_id : nil
      AgentMessage.transaction(requires_new: true) do
        person = AgentPerson.resolve!(platform: self.class::CHANNEL, external_id: author_ref, display_name: name)
        rows = results.each_with_index.map do |result, index|
          store_one(event, index.zero? ? external_id : sibling_id(event, result.soul), result, person, name, fan, ctx)
        end
        rows.first
      end
    end

    def store_one(event, external_id, result, person, name, fan, ctx)
      unserved = result.routed? && !@routes.answers?(result.soul)
      uncleared = result.routed? && !@routes.cleared?(event["channel"], result.soul)
      unanswered = result.routed? && !@answerers.allowed?(person)
      held = unserved || uncleared || unanswered
      message = AgentMessage.create!(
        {
          channel: self.class::CHANNEL, external_id: external_id, thread_key: thread_key(event),
          author_ref: event["user"].to_s, author_name: name, person: person, content: event["text"].to_s,
          soul_slug: result.soul, routed_by: result.routed_by, status: status_for(result, held)
        }.merge(row_attributes(event, ctx.merge(fan: fan)))
      )
      message.record!("received", actor: self.class::RECEIVED_ACTOR, detail: { "author" => message.author_name })
      message.record!(result.routed? ? "routed" : "unrouted", actor: "router",
                      detail: result.detail.merge("soul" => result.soul, "routed_by" => result.routed_by).compact)
      if held
        record_held(message, event, result, person, unserved: unserved, uncleared: uncleared, unanswered: unanswered)
      end
      message
    end

    # One `held` event naming every cause: a soul no dispatcher serves on this
    # medium, the channel's clearance (the soul may not answer here), and/or the
    # owner-only guard (the sender is not answered).
    def record_held(message, event, result, person, unserved:, uncleared:, unanswered:)
      reasons = []
      reasons << @routes.unanswerable_reason(result.soul) if unserved
      reasons << @routes.clearance_reason(event["channel"], result.soul) if uncleared
      reasons << @answerers.held_reason(person) if unanswered
      actor = unserved || uncleared ? "#{self.class::CHANNEL}-clearance" : "answerers"
      detail = { "reason" => reasons.join("; "), "person_id" => person&.id }
      detail["cleared"] = @routes.cleared_souls(event["channel"]) if uncleared
      message.record!("held", actor: actor, detail: detail.compact)
    end

    # The oldest row the mailbox holds in this message's thread (a reply in a
    # thread only: thread_ts set and not the message itself), or nil. A routed
    # row before an unrouted one and one not held before a held one, so after a
    # fan-out the follow-up goes to the first-named soul that may answer.
    def thread_row(event)
      return nil if event["thread_ts"].blank? || event["thread_ts"] == event["ts"]

      AgentMessage.where(channel: self.class::CHANNEL, channel_ref: event["channel"].to_s, thread_key: thread_key(event))
                  .order(Arel.sql("soul_slug IS NULL"), Arel.sql("status = 'held'"), :id).first
    end

    def status_for(result, held)
      return "unrouted" unless result.routed?

      held ? "held" : "received"
    end
  end
end
