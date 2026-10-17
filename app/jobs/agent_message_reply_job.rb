# Posts a completed AgentMessage's answer back to Discord, once (an EMAIL row's
# answer is mailed instead, by AgentMessages::EmailReply through Resend, and a WEB
# row's is pushed to the open chat, by AgentMessages::WebChat.deliver!)
# (docs/agents/system/agent-message-loop.md). Enqueued by AgentMessage#complete!
# only on the transition into `completed`, so a repeated complete queues nothing.
#
# ONCE, two ways: a row with a reply_external_id is never posted again, and the
# post carries the row's stable reply_nonce with enforce_nonce, so a retry after
# a lost response gets Discord's existing message back instead of a second one.
#
# WHICH BOT. A soul with its own Discord app (DISCORD_BOT_TOKEN_<SOUL>, e.g.
# DISCORD_BOT_TOKEN_AVI) replies as that bot, unsigned: the bot's name already
# says who answered. Without one (absent or blank) the shared bot
# (DISCORD_AGENT_BOT_TOKEN) replies, signed `**Soul** · …`, exactly as before.
# AgentMessages::BotSelector makes the pick, shared with the CTO reports.
# If the soul's bot is refused (401/403: a bad token, a bot not in the guild, a
# missing channel permission), the job writes an ErrorLog and a
# `reply_bot_refused` event and falls back to the shared bot, once: a later try
# of the same job sees the event and goes straight to the shared bot.
#
# With no usable bot token the reply is skipped and recorded on the timeline; the
# answer stays on the row, visible on /admin/agent_messages.
class AgentMessageReplyJob < ApplicationJob
  queue_as :default
  retry_on AgentMessages::DiscordBot::Error, wait: :polynomially_longer, attempts: 5 do |job, error|
    message = AgentMessage.find_by(id: job.arguments.first)
    next unless message

    message.update_column(:reply_status, "failed")
    message.record!("reply_failed", actor: "discord-bot", detail: { "error" => error.message.to_s[0, 300] })
  end

  REFUSED_EVENT = "reply_bot_refused".freeze

  def perform(message_id)
    message = AgentMessage.find_by(id: message_id)
    return if message.nil? || message.status != "completed" || message.reply_external_id.present?
    return AgentMessages::EmailReply.deliver!(message) if message.channel == "email"
    return AgentMessages::WebChat.deliver!(message) if message.web?
    return if message.channel != "discord"

    posted, via = AgentMessages::BotSelector.post(message.soul_slug, skip_soul: message.events.exists?(kind: REFUSED_EVENT),
                                                                     on_refused: ->(error, _env) { refused!(message, error) }) do |bot, chosen|
      post(bot, message, signed: chosen == AgentMessages::BotSelector::SHARED)
    end
    return no_bot!(message) if posted.nil?

    message.update!(reply_external_id: posted["id"].to_s, reply_posted_at: Time.current, reply_status: "posted")
    message.record!("reply_posted", actor: "discord-bot",
                                    detail: { "reply_id" => posted["id"].to_s, "url" => message.reply_url, "via" => via })
  end

  # The answer as posted. The shared bot signs it with the soul's display name,
  # so its replies say who answered; a soul's own bot does not need to.
  def self.reply_text(message, signed: true)
    signed ? "**#{display_name(message.soul_slug)}** · #{message.response_text}" : message.response_text.to_s
  end

  # A domain's front door signs as its registry `reply_name` (Turf, not
  # "Turf Monster"), else the Agent's name.
  def self.display_name(soul)
    AgentProposal.registry.reply_name(soul) || Agent.find_by(slug: soul)&.name.presence || soul.to_s.titleize
  end

  private

  # No bot could post (AgentMessages::BotSelector answered nil): the shared
  # bot has no token. After a refused soul bot that is a failure; otherwise the
  # reply is skipped. Either way it is recorded on the timeline.
  def no_bot!(message)
    unset = AgentMessages::DiscordBot::TOKEN_ENV
    if message.events.exists?(kind: REFUSED_EVENT)
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

  def post(bot, message, signed:)
    bot.post_reply(message.channel_ref, content: self.class.reply_text(message, signed: signed),
                                        reference_id: message.external_id,
                                        nonce: message.reply_nonce.presence || "agentmsg-#{message.id}")
  end

  # The error names the ENV var and Discord's answer, never the token
  # (DiscordBot redacts it from everything it raises).
  def refused!(message, error)
    env = AgentMessages::DiscordBot.soul_token_env(message.soul_slug)
    entry = ErrorLog.capture!(error)
    entry.update(target: message, target_name: "#{env} reply for message #{message.id}")
    message.record!(REFUSED_EVENT, actor: "discord-bot", detail: { "token_env" => env, "error" => error.message.to_s[0, 300] })
  rescue StandardError => e
    Rails.logger.warn("[agent-messages] could not record a refused soul bot: #{e.class}")
  end
end
