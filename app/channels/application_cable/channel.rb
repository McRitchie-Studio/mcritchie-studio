module ApplicationCable
  # Every hub channel refuses a subscriber who is not an admin unless it says
  # otherwise: the connection admits any signed-in user (connection.rb), so the
  # channel is where a stream is kept to the people who may hear it. A channel
  # for non-admins (CtoChatChannel) overrides `authorized?` with its own check.
  class Channel < ActionCable::Channel::Base
    before_subscribe :require_authorized

    private

    def authorized? = current_user.respond_to?(:admin?) && current_user.admin?

    # A refusal skips `subscribed` (the abort) and transmits the rejection.
    def require_authorized
      return if authorized?

      reject
      throw :abort
    end
  end
end
