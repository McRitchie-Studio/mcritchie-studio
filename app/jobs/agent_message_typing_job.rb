# Shows the replying bot as "typing…" in the channel of a message being
# answered (docs/agents/system/agent-message-loop.md, "Typing"). One job is one
# pulse: POST /channels/{id}/typing, which Discord shows for about ten seconds
# or until that bot posts. bin/dispatcher asks for a pulse when its run starts
# and every AgentMailbox::Dispatcher::TYPING_EVERY seconds while the run lives
# (POST /api/v1/agent_messages/:id/typing), so typing lasts as long as the run
# and stops with it: on the reply, a failure, a usage limit or a give-back.
#
# THE WEB CHAT has no bot: its pulse is a Turbo Stream broadcast to the sender's
# open chat (AgentMessages::WebChat.broadcast_typing), which shows "<CTO> is
# typing…" and fades it on its own a few seconds after the last pulse.
#
# BEST EFFORT, NEVER IN THE WAY. A pulse is re-checked here
# (AgentMessage#typing_refusal: still claimed by that worker, a Discord message,
# a sender the board answers, within TYPING_CAP of the claim) and dropped when it
# fails. A Discord error (a timeout, a 5xx, a 429) is logged by class and
# dropped, never retried: a late pulse is worse than none, and the next one is
# seconds away. (Anything else takes ApplicationJob's retry, and the retry
# re-checks the guard, so it can never type for a finished run.)
#
# WHICH BOT. The same one the reply will use (AgentMessages::BotSelector): the
# soul's own bot when DISCORD_BOT_TOKEN_<SOUL> is set, else the shared bot. A
# 401/403 from the soul's bot falls back to the shared bot in the same call and
# records one `typing_bot_refused` event, so later pulses go straight to the
# shared bot; a soul bot the reply job already found refused is skipped too. No
# usable token: no typing, silently. The reply job's own choice is untouched.
class AgentMessageTypingJob < ApplicationJob
  queue_as :default

  REFUSED_EVENT = "typing_bot_refused".freeze

  def perform(message_id, worker)
    message = AgentMessage.find_by(id: message_id)
    return if message.nil? || message.typing_refusal(worker: worker)
    return AgentMessages::WebChat.broadcast_typing(message) if message.web?

    skip_soul = message.events.exists?(kind: [ REFUSED_EVENT, AgentMessageReplyJob::REFUSED_EVENT ])
    AgentMessages::BotSelector.post(message.soul_slug, skip_soul: skip_soul,
                                                       on_refused: ->(_error, env) { refused!(message, env) }) do |bot, _via|
      bot.trigger_typing(message.channel_ref)
    end
  rescue AgentMessages::DiscordBot::Error => e
    # The class only: DiscordBot already keeps the token out of its errors, and
    # a dropped pulse needs no more than this.
    Rails.logger.info("[agent-messages] typing pulse for message #{message_id} dropped: #{e.class}")
  end

  private

  # Once per message: the timeline says the soul's bot could not type, naming
  # the ENV var, never the token or Discord's body.
  def refused!(message, env)
    return if message.events.exists?(kind: REFUSED_EVENT)

    message.record!(REFUSED_EVENT, actor: "discord-bot", detail: { "token_env" => env })
  rescue StandardError => e
    Rails.logger.warn("[agent-messages] could not record a refused typing bot: #{e.class}")
  end
end
