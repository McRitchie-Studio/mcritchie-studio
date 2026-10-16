# A CTO's answer to an email, sent as that CTO through the hub's Resend path
# (Studio::Email.deliver, the durable outbox) by AgentMessages::EmailReply
# (docs/agents/system/agent-message-loop.md, "Email").
#
#   From         the soul's configured sender (config/agent_routes.yml `email:`),
#                e.g. "Avi <avi@mcritchie.studio>", on the verified mcritchie.studio domain
#   To           the VERIFIED sender of the email it answers (envelope "from"),
#                never a Reply-To the sender's mail named
#   Reply-To     team@mcritchie.studio, so the next turn comes back through the inbound
#   Subject      "Re: <subject>"
#   In-Reply-To  the answered mail's Message-ID; References its References plus it
#   Message-ID   reply_message_id(message), stored as reply_external_id, so a
#                reply to this answer can name it
#   Auto-Submitted: auto-replied (RFC 3834), and X-McRitchie-Agent: <soul>, which
#                AgentMessages::EmailLoopGuard reads so we never answer ourselves
#
# Plain text only. The answer's markdown bold is dropped; nothing else is rendered.
class AgentReplyMailer < ApplicationMailer
  REFERENCES_KEPT = 20

  # Stable across outbox retries (it is rendered again on each try): the row's id
  # and its creation second, so two databases' row 12 do not share one id.
  def self.reply_message_id(message) = "agentmsg-#{message.id}.#{message.created_at.to_i}@mcritchie.studio"

  # Resend's idempotency key, scoped to this environment and app host: QA's row 12
  # and production's row 12 share a nonce, never a key.
  def self.idempotency_key(message)
    host = ENV["APP_HOST"].presence || ENV["HEROKU_APP_NAME"].presence || "app"
    "#{Rails.env}:#{host}:#{message.reply_nonce.presence || "agentmsg-#{message.id}"}"
  end

  def self.subject_for(subject)
    base = subject.to_s.strip
    return "Re: your message" if base.empty?

    base.match?(/\Are:/i) ? base : "Re: #{base}"
  end

  def self.body_for(message)
    text = message.response_text.to_s.gsub(/\*\*(.+?)\*\*/m, '\1').strip
    "#{text}\n\n-- \n#{AgentMessageReplyJob.display_name(message.soul_slug)}\n"
  end

  def reply(message_id)
    message = AgentMessage.find(message_id)
    envelope = message.envelope.to_h
    routes = AgentMessages::EmailRoutes.current
    original = envelope["message_id"].to_s
    references = (Array(envelope["references"]) + [ original ]).compact_blank.uniq.last(REFERENCES_KEPT)

    headers["In-Reply-To"] = "<#{original}>" if original.present?
    headers["References"] = references.map { |id| "<#{id}>" }.join(" ") if references.any?
    headers["Auto-Submitted"] = "auto-replied"
    headers[AgentMessages::EmailLoopGuard::AGENT_HEADER] = message.soul_slug.to_s

    mail(from: routes.from_for(message.soul_slug) || Studio.mailer_from,
         to: envelope["from"],
         reply_to: routes.team_address,
         subject: self.class.subject_for(envelope["subject"]),
         message_id: "<#{self.class.reply_message_id(message)}>",
         options: { idempotency_key: self.class.idempotency_key(message) }) do |format|
      format.text { render plain: self.class.body_for(message) }
    end
  end
end
