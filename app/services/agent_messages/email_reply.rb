module AgentMessages
  # Sends a completed email row's answer, ONCE, through the hub's existing
  # Resend path (Studio::Email.deliver → the studio_email_deliveries outbox →
  # AgentReplyMailer#reply), called by AgentMessageReplyJob
  # (docs/agents/system/agent-message-loop.md, "Email").
  #
  # ONCE, three ways, as Discord's nonce: the row is locked and a row with a
  # reply_external_id is never sent again; the outbox row is the durable intent
  # (a provider outage leaves it unsent for Studio::EmailDelivery.resend_unsent!,
  # never lost); and the send carries the row's reply_nonce as Resend's
  # idempotency key, so a retried outbox job cannot send twice.
  #
  # An email row is answered only to its VERIFIED sender. A row with no verified
  # From (it would have been held, and an admin may still release one) is
  # skipped with a `reply_skipped` event rather than mailed to an unproven address.
  class EmailReply
    def self.deliver!(message) = new(message).deliver!

    def initialize(message)
      @message = message
    end

    def deliver!
      @message.with_lock do
        return :already if @message.reply_external_id.present?

        to = @message.envelope.to_h["from"].to_s
        unless @message.envelope.to_h.dig("trust", "verified") == true && to.present?
          @message.update!(reply_status: "skipped")
          @message.record!("reply_skipped", actor: "email", detail: { "reason" => "the sender is not verified; no reply is mailed" })
          return :skipped
        end

        @message.update!(reply_nonce: @message.reply_nonce.presence || "agentmsg-#{@message.id}")
        delivery = Studio::Email.deliver(AgentReplyMailer, :reply, @message.id, to: to)
        message_id = AgentReplyMailer.reply_message_id(@message)
        @message.update!(reply_external_id: message_id, reply_posted_at: Time.current, reply_status: "posted")
        @message.record!("reply_posted", actor: "email",
                                         detail: { "via" => "resend", "message_id" => message_id,
                                                   "outbox_id" => (delivery.id if delivery.respond_to?(:id)) }.compact)
        :posted
      end
    end
  end
end
