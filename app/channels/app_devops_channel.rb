# The live side of an app chat's status card (AppDevopsStages::Live): one stream
# per app, carrying only "reload your card" (a frame src), never task content.
# The page subscribes with
# `turbo_stream_from AppDevopsStages::Live.stream_name(app), channel: AppDevopsChannel`.
#
# Admitted only when the signed stream name is an app-devops stream and the
# viewer may manage that app (AppOwnership.manage_app?: the app's owner or an
# admin), the same rule as the chat page itself.
class AppDevopsChannel < ApplicationCable::Channel
  extend Turbo::Streams::Broadcasts
  extend Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  def subscribed
    stream_from @stream_name
  end

  private

  def authorized?
    @stream_name = verified_stream_name_from_params
    app_slug = AppDevopsStages::Live.parse_stream(@stream_name)
    return false unless app_slug && current_user

    AppOwnership.manage_app?(current_user, app_slug)
  end
end
