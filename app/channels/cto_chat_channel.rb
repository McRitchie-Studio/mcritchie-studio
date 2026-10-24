# The live side of a CTO web chat (docs/agents/system/agent-message-loop.md,
# "Web chat"; AgentMessages::WebChat): the page subscribes with
# `turbo_stream_from AgentMessages::WebChat.stream_name(app, user), channel: CtoChatChannel`.
#
# Admitted only when the signed stream name is a chat stream, it names THIS
# user, and they may still manage that app (AppOwnership.manage_app?: the app's
# owner or an admin). So a stream name copied from someone else's page, a forged
# one, or one kept after an ownership ends hears nothing. An admin, too, hears
# only their own chats: a chat stream is per user.
class CtoChatChannel < ApplicationCable::Channel
  extend Turbo::Streams::Broadcasts
  extend Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  def subscribed
    stream_from @stream_name
  end

  private

  def authorized?
    @stream_name = verified_stream_name_from_params
    app_slug, user_id = AgentMessages::WebChat.parse_stream(@stream_name)
    return false unless app_slug && current_user && user_id == current_user.id

    AppOwnership.manage_app?(current_user, app_slug)
  end
end
