module Media
  # The interface every medium implements (Media.adapter returns one). A method
  # a medium has no use for yet raises NotImplementedError, so a caller that
  # reaches one learns it at once instead of silently doing nothing; the hooks
  # below are documented for the cards that fill them
  # (.agents/epics/omnichannel-media.md).
  #
  #   key            the medium's name, the value AgentMessage#channel holds
  #   capabilities   what it can do today: :reply, :typing (more as they land)
  #   inbound_mode   how messages arrive: :gateway, :webhook, :http
  #   configured?    whether its credentials are present
  #   enabled?       whether the hub should use it (configured, by default)
  #   deliver_reply  post a completed message's answer back, once
  #   typing         one "typing…" pulse while an answer runs
  #   message_url    a link to a message on the medium, or nil
  #   setup_kit      the AgentSetups kit kind that installs it, or nil
  #   post           a standalone post to a Media::Home (Media.post): the floor
  #                  alert, release notes, app requests; capability :post
  #   actor          who an event on a message's timeline names for this medium
  class Adapter
    def key = raise(NotImplementedError, "#{self.class.name}#key")

    def capabilities = []

    def supports?(capability) = capabilities.include?(capability.to_sym)

    def inbound_mode = raise(NotImplementedError, "#{self.class.name}#inbound_mode")

    def configured? = raise(NotImplementedError, "#{self.class.name}#configured?")

    def enabled? = configured?

    # Post `message`'s answer on this medium, once; the row records the outcome
    # (reply_status, a reply_posted / reply_skipped / reply_failed event).
    def deliver_reply(_message) = raise(NotImplementedError, "#{self.class.name}#deliver_reply")

    # One typing pulse. A medium without :typing does nothing.
    def typing(_message, phase:) = nil

    def message_url(_message, _message_id = nil) = nil

    def setup_kit = nil

    # A standalone message into a home (a channel on this medium), not a reply.
    def post(*, **) = raise(NotImplementedError, "#{self.class.name}#post")

    def actor = "#{key}-bot"

    def inspect = "#<#{self.class.name} key=#{key}>"
  end
end
