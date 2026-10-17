module AgentMessages
  # The web chat's delivery side (docs/agents/system/agent-message-loop.md, "Web
  # chat"): what the hub pushes to an open /applications/:slug/chat page over its
  # Turbo stream. WebIngest stores the message; everything after is here.
  #
  #   broadcast_turn(m, append: true)  a new turn, appended (CtoChatsController#create)
  #   broadcast_typing(m)              one "typing…" pulse (AgentMessageTypingJob):
  #                                    the page shows it and fades it after
  #                                    TYPING_FADE seconds without another pulse
  #   deliver!(m)                      the answer (AgentMessageReplyJob): marked
  #                                    posted ONCE, then the turn replaced in place,
  #                                    typing cleared and the usage meter redrawn
  #
  # THE STREAM is one per user per app (`cto_chat:<app slug>:<user id>`), and
  # CtoChatChannel lets only that user subscribe, and only while they may still
  # manage the app. A broadcast carries only that user's own thread.
  #
  # BEST EFFORT, NEVER LOST. The answer is durable on the row before any
  # broadcast; a broadcast that fails (Redis down) is logged, and the page shows
  # the answer on its next load. Nothing here retries a broadcast.
  module WebChat
    MESSAGES_TARGET = "cto-chat-messages".freeze
    TYPING_TARGET = "cto-chat-typing".freeze
    METER_TARGET = "cto-chat-meter".freeze
    # The page fades a typing indicator this long after the last pulse (the
    # dispatcher pulses every 7 seconds while the run lives), so a run that dies
    # stops showing typing within seconds, as on Discord.
    TYPING_FADE = 12
    HISTORY = 50

    module_function

    def stream_name(app_slug, user_id) = "cto_chat:#{app_slug}:#{user_id}"
    def thread_key(app_slug, user_id) = "web:#{app_slug}:#{user_id}"

    # The [app slug, user id] a stream name names, or nil when it is not one.
    def parse_stream(name)
      match = /\Acto_chat:(?<app>[a-z0-9-]{1,60}):(?<user>\d{1,18})\z/.match(name.to_s)
      match ? [ match[:app], match[:user].to_i ] : nil
    end

    def stream_for(message) = stream_name(message.channel_ref, message.author_ref)

    # The thread's newest HISTORY turns, oldest first.
    def history(app_slug, user_id)
      AgentMessage.where(channel: "web", thread_key: thread_key(app_slug, user_id))
                  .order(id: :desc).limit(HISTORY).to_a.reverse
    end

    def broadcast_turn(message, append: false)
      options = { partial: "agent_chats/turn", locals: { message: message, agent_name: cto_name(message) } }
      if append
        Turbo::StreamsChannel.broadcast_append_to(stream_for(message), target: MESSAGES_TARGET, **options)
      else
        Turbo::StreamsChannel.broadcast_replace_to(stream_for(message), target: turn_id(message), **options)
      end
      true
    rescue StandardError => e
      log(e, message, "turn")
    end

    def broadcast_typing(message, now: Time.current)
      return false if BuildIntake.thread?(message.thread_key)

      # UPDATE, not replace: the slot (#cto-chat-typing, which carries the fade)
      # stays on the page, and only its contents change.
      Turbo::StreamsChannel.broadcast_update_to(stream_for(message), target: TYPING_TARGET, partial: "agent_chats/typing",
                                                                     locals: { agent_name: cto_name(message), at: now })
      true
    rescue StandardError => e
      log(e, message, "typing")
    end

    # The answer, delivered once: the row is locked, a row with a
    # reply_external_id is never delivered again, and the mark is written before
    # the broadcast, so a retried job neither re-marks nor re-broadcasts.
    def deliver!(message, now: Time.current)
      delivered = AgentMessage.transaction do
        message.lock!
        next false if message.reply_external_id.present? || message.status != "completed"

        message.update!(reply_external_id: "web:#{message.id}", reply_posted_at: now, reply_status: "posted")
        message.record!("reply_posted", actor: "web-chat", detail: { "via" => "web_chat" })
        true
      end
      return false unless delivered
      # A /build thread has no stream: its page polls (BuildController#turns),
      # since a signed-out visitor has no /cable socket.
      return true if BuildIntake.thread?(message.thread_key)

      broadcast_turn(message)
      clear_typing(message)
      broadcast_meter(message)
      true
    end

    def clear_typing(message)
      Turbo::StreamsChannel.broadcast_update_to(stream_for(message), target: TYPING_TARGET, html: "")
    rescue StandardError => e
      log(e, message, "typing clear")
    end

    # The meter as the chat shows it: tokens only (an owner never sees dollars;
    # the partial prints none for anyone).
    def broadcast_meter(message)
      app = App.find_by(slug: message.channel_ref)
      return unless app

      Turbo::StreamsChannel.broadcast_update_to(stream_for(message), target: METER_TARGET, partial: "applications/usage_meter",
                                                                     locals: { meter: AgentUsage.meter(app).without_cost })
    rescue StandardError => e
      log(e, message, "meter")
    end

    def turn_id(message) = "cto-chat-turn-#{message.id}"

    def cto_name(message)
      AgentProposal.registry.reply_name(message.soul_slug) || Agent.find_by(slug: message.soul_slug.to_s.tr("_", "-"))&.name ||
        message.soul_slug.to_s.titleize
    end

    def log(error, message, what)
      Rails.logger.warn("[agent-messages] web chat #{what} broadcast for message #{message.id} failed: #{error.class}")
      ErrorLog.capture!(error)&.update(target: message, target_name: "web chat #{what} for message #{message.id}")
      false
    rescue StandardError
      false
    end
  end
end
