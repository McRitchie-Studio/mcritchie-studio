module Media
  # The web chat (/applications/:slug/chat, /build, a satellite's chat): the
  # message arrives over HTTP (AgentMessages::WebIngest) and everything after is
  # AgentMessages::WebChat: the answer delivered once, typing as a Turbo Stream
  # pulse that says "thinking" or "typing".
  class Web < Adapter
    def key = "web"
    def capabilities = %i[reply typing]
    def inbound_mode = :http
    def configured? = true

    def deliver_reply(message) = AgentMessages::WebChat.deliver!(message)

    def typing(message, phase:) = AgentMessages::WebChat.broadcast_typing(message, phase: phase)
  end
end
