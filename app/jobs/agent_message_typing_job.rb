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
# thinking" or "<CTO> is typing" (the pulse's phase) and fades it on its own a
# few seconds after the last pulse.
#
# BEST EFFORT, NEVER IN THE WAY. A pulse is re-checked here
# (AgentMessage#typing_refusal: still claimed by that worker, a Discord message,
# a sender the board answers, within TYPING_CAP of the claim) and dropped when it
# fails. A Discord error (a timeout, a 5xx, a 429) is logged by class and
# dropped, never retried: a late pulse is worse than none, and the next one is
# seconds away. (Anything else takes ApplicationJob's retry, and the retry
# re-checks the guard, so it can never type for a finished run.)
#
# WHICH MEDIUM. The row's `channel` picks the adapter (Media.adapter).
# Media::Discord types as the same bot the reply will use
# (AgentMessages::BotSelector): the soul's own bot when DISCORD_BOT_TOKEN_<SOUL>
# is set, else the shared bot. A 401/403 from the soul's bot falls back to the
# shared bot in the same call and records one `typing_bot_refused` event, so
# later pulses go straight to the shared bot; a soul bot the reply job already
# found refused is skipped too. No usable token: no typing, silently. A medium
# error (a Media::Error) is logged by class and dropped.
class AgentMessageTypingJob < ApplicationJob
  queue_as :default

  REFUSED_EVENT = Media::Discord::TYPING_REFUSED_EVENT

  # `phase`: the web chat's "thinking" or "typing" (AgentMessage.typing_phase
  # allow-lists it again here; a job queued before phases has none: typing).
  # A Discord pulse looks the same whatever it says.
  def perform(message_id, worker, phase = nil)
    message = AgentMessage.find_by(id: message_id)
    return if message.nil? || message.typing_refusal(worker: worker)
    return unless Media.supports?(message.channel, :typing) # unregistered, Email, Slack or Teams (no typing yet)

    Media.adapter(message.channel).typing(message, phase: AgentMessage.typing_phase(phase))
  rescue Media::Error => e
    # The class only: DiscordBot already keeps the token out of its errors, and
    # a dropped pulse needs no more than this.
    Rails.logger.info("[agent-messages] typing pulse for message #{message_id} dropped: #{e.class}")
  end
end
