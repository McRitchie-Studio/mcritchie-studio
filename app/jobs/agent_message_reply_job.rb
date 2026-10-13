# Posts a completed AgentMessage's answer back to Discord, once
# (docs/agents/system/agent-message-loop.md). Enqueued by AgentMessage#complete!
# only on the transition into `completed`, so a repeated complete queues nothing.
#
# ONCE, two ways: a row with a reply_external_id is never posted again, and the
# post carries the row's stable reply_nonce with enforce_nonce, so a retry after
# a lost response gets Discord's existing message back instead of a second one.
#
# With no bot token the reply is skipped and recorded on the timeline; the answer
# stays on the row, visible on /admin/agent_messages.
class AgentMessageReplyJob < ApplicationJob
  queue_as :default
  retry_on AgentMessages::DiscordBot::Error, wait: :polynomially_longer, attempts: 5 do |job, error|
    message = AgentMessage.find_by(id: job.arguments.first)
    message&.record!("reply_failed", actor: "discord-bot", detail: { "error" => error.message.to_s[0, 300] })
  end

  def perform(message_id)
    message = AgentMessage.find_by(id: message_id)
    return if message.nil? || message.status != "completed" || message.reply_external_id.present?
    return if message.channel != "discord"

    unless AgentMessages::DiscordBot.configured?
      message.record!("reply_skipped", actor: "discord-bot",
                                       detail: { "reason" => "#{AgentMessages::DiscordBot::TOKEN_ENV} is unset" })
      return
    end

    posted = AgentMessages::DiscordBot.new.post_reply(message.channel_ref, content: self.class.reply_text(message),
                                                      reference_id: message.external_id,
                                                      nonce: message.reply_nonce.presence || "agentmsg-#{message.id}")
    message.update!(reply_external_id: posted["id"].to_s, reply_posted_at: Time.current)
    message.record!("reply_posted", actor: "discord-bot", detail: { "reply_id" => posted["id"].to_s, "url" => message.reply_url })
  end

  # The soul's display name leads, so a shared bot's replies say who answered.
  def self.reply_text(message)
    "**#{display_name(message.soul_slug)}** · #{message.response_text}"
  end

  def self.display_name(soul)
    Agent.find_by(slug: soul)&.name.presence || soul.to_s.titleize
  end
end
