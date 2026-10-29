module Media
  # Email: delivery only. Mail arrives through the Resend inbound webhook
  # (AgentMessages::EmailIngest); the answer is mailed once by
  # AgentMessages::EmailReply. Email has no typing indicator.
  class Email < Adapter
    def key = "email"
    def capabilities = %i[reply]
    def inbound_mode = :webhook
    def configured? = true

    def deliver_reply(message) = AgentMessages::EmailReply.deliver!(message)
  end
end
