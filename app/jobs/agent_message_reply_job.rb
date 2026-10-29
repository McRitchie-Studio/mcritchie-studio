# Posts a completed AgentMessage's answer back on the medium it arrived on,
# once: a Discord reply, an EMAIL row's answer mailed by AgentMessages::EmailReply
# through Resend, a WEB row's pushed to the open chat by AgentMessages::WebChat
# (docs/agents/system/agent-message-loop.md). Enqueued by AgentMessage#complete!
# only on the transition into `completed`, so a repeated complete queues nothing.
#
# ONCE, two ways: a row with a reply_external_id is never posted again, and the
# post carries the row's stable reply_nonce with enforce_nonce, so a retry after
# a lost response gets Discord's existing message back instead of a second one.
#
# WHICH MEDIUM. The row's own `channel` picks the adapter (Media.adapter): a
# reply always goes back on the medium the message arrived on. Media::Discord
# holds the bot choice, the signing, the refused-soul-bot fallback and the
# skipped/failed bookkeeping; Media::Email and Media::Web wrap EmailReply and
# WebChat. A channel no adapter names is left alone.
#
# RETRY. A medium's failure is a Media::Error (AgentMessages::DiscordBot::Error
# is one; email and web raise no Media::Error): five polynomial tries, then the row is
# marked failed. With no usable bot token the reply is skipped and recorded on
# the timeline; the answer stays on the row, visible on /admin/agent_messages.
class AgentMessageReplyJob < ApplicationJob
  queue_as :default
  retry_on Media::Error, wait: :polynomially_longer, attempts: 5 do |job, error|
    message = AgentMessage.find_by(id: job.arguments.first)
    next unless message

    message.update_column(:reply_status, "failed")
    message.record!("reply_failed", actor: "discord-bot", detail: { "error" => error.message.to_s[0, 300] })
  end

  REFUSED_EVENT = Media::Discord::REPLY_REFUSED_EVENT

  def perform(message_id)
    message = AgentMessage.find_by(id: message_id)
    return if message.nil? || message.status != "completed" || message.reply_external_id.present?
    return unless Media.registered?(message.channel)

    Media.adapter(message.channel).deliver_reply(message)
  end

  # Kept for their callers (AgentReplyMailer signs with display_name).
  def self.reply_text(message, signed: true) = Media::Discord.reply_text(message, signed: signed)
  def self.display_name(soul) = Media.display_name(soul)
end
