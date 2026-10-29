module Media
  # Discord: messages arrive over the Gateway websocket (AgentMessages::
  # DiscordGateway, with the REST poll as backstop); replies and typing go out
  # through AgentMessages::DiscordBot, the bot picked by
  # AgentMessages::BotSelector. This adapter is the reply and typing logic the
  # two jobs used to hold, moved here unchanged
  # (docs/agents/system/agent-message-loop.md).
  #
  # REPLY, ONCE, two ways: the job never calls it for a row with a
  # reply_external_id, and the post carries the row's stable reply_nonce with
  # enforce_nonce, so a retry after a lost response gets Discord's existing
  # message back instead of a second one.
  #
  # WHICH BOT. A soul with its own Discord app (DISCORD_BOT_TOKEN_<SOUL>) replies
  # as that bot, unsigned: the bot's name already says who answered. Without one
  # the shared bot (DISCORD_AGENT_BOT_TOKEN) replies, signed `**Soul** · …`. A
  # 401/403 from the soul's bot writes an ErrorLog and a `reply_bot_refused`
  # event and falls back to the shared bot, once: a later try sees the event and
  # goes straight to the shared bot. Typing picks the same bot, and records
  # `typing_bot_refused` once on a refusal.
  #
  # Errors are AgentMessages::DiscordBot::Error, a Media::Error: the reply job
  # retries on it, the typing job drops it.
  class Discord < Adapter
    REPLY_REFUSED_EVENT = "reply_bot_refused".freeze
    TYPING_REFUSED_EVENT = "typing_bot_refused".freeze

    def key = "discord"
    def capabilities = %i[reply typing]
    def inbound_mode = :gateway
    def configured? = AgentMessages::DiscordBot.configured?
    def setup_kit = "discord_bot"

    def message_url(message, message_id = message.external_id) = message.discord_url(message_id)

    # The answer as posted. The shared bot signs it with the soul's display
    # name, so its replies say who answered; a soul's own bot does not need to.
    def self.reply_text(message, signed: true)
      signed ? "**#{Media.display_name(message.soul_slug)}** · #{message.response_text}" : message.response_text.to_s
    end

    def deliver_reply(message)
      posted, via = AgentMessages::BotSelector.post(message.soul_slug, skip_soul: message.events.exists?(kind: REPLY_REFUSED_EVENT),
                                                                       on_refused: ->(error, _env) { reply_refused!(message, error) }) do |bot, chosen|
        post_reply(bot, message, signed: chosen == AgentMessages::BotSelector::SHARED)
      end
      return no_bot!(message) if posted.nil?

      message.update!(reply_external_id: posted["id"].to_s, reply_posted_at: Time.current, reply_status: "posted")
      message.record!("reply_posted", actor: "discord-bot",
                                      detail: { "reply_id" => posted["id"].to_s, "url" => message.reply_url, "via" => via })
    end

    # One pulse: POST /channels/{id}/typing as the bot the reply will use. A
    # soul bot already refused (for typing or the reply) is skipped. A pulse
    # looks the same whatever its phase says.
    def typing(message, phase: nil)
      skip_soul = message.events.exists?(kind: [ TYPING_REFUSED_EVENT, REPLY_REFUSED_EVENT ])
      AgentMessages::BotSelector.post(message.soul_slug, skip_soul: skip_soul,
                                                         on_refused: ->(_error, env) { typing_refused!(message, env) }) do |bot, _via|
        bot.trigger_typing(message.channel_ref)
      end
    end

    private

    # No bot could post (BotSelector answered nil): the shared bot has no
    # token. After a refused soul bot that is a failure; otherwise the reply is
    # skipped. Either way it is recorded on the timeline.
    def no_bot!(message)
      unset = AgentMessages::DiscordBot::TOKEN_ENV
      if message.events.exists?(kind: REPLY_REFUSED_EVENT)
        message.update_column(:reply_status, "failed")
        message.record!("reply_failed", actor: "discord-bot",
                                        detail: { "error" => "the soul's own bot was refused and #{unset} is unset" })
      else
        soul_env = AgentMessages::DiscordBot.soul_token_env(message.soul_slug)
        message.update_column(:reply_status, "skipped")
        message.record!("reply_skipped", actor: "discord-bot", detail: { "reason" => "#{soul_env} and #{unset} are unset" })
      end
      nil
    end

    def post_reply(bot, message, signed:)
      bot.post_reply(message.channel_ref, content: self.class.reply_text(message, signed: signed),
                                          reference_id: message.external_id,
                                          nonce: message.reply_nonce.presence || "agentmsg-#{message.id}")
    end

    # The error names the ENV var and Discord's answer, never the token
    # (DiscordBot redacts it from everything it raises).
    def reply_refused!(message, error)
      env = AgentMessages::DiscordBot.soul_token_env(message.soul_slug)
      entry = ErrorLog.capture!(error)
      entry.update(target: message, target_name: "#{env} reply for message #{message.id}")
      message.record!(REPLY_REFUSED_EVENT, actor: "discord-bot", detail: { "token_env" => env, "error" => error.message.to_s[0, 300] })
    rescue StandardError => e
      Rails.logger.warn("[agent-messages] could not record a refused soul bot: #{e.class}")
    end

    # Once per message: the timeline says the soul's bot could not type, naming
    # the ENV var, never the token or Discord's body.
    def typing_refused!(message, env)
      return if message.events.exists?(kind: TYPING_REFUSED_EVENT)

      message.record!(TYPING_REFUSED_EVENT, actor: "discord-bot", detail: { "token_env" => env })
    rescue StandardError => e
      Rails.logger.warn("[agent-messages] could not record a refused typing bot: #{e.class}")
    end
  end
end
