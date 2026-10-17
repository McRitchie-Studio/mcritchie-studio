module ApplicationCable
  # Turbo::StreamsChannel (every `turbo_stream_from` without a `channel:`) admits
  # admins only. Its streams (the deployments board, the activity feed) are ops
  # HTML, and the connection now admits any signed-in user, so this is the check
  # that keeps a signed stream name an owner might hold from streaming them.
  # Prepended by config/initializers/turbo_streams_admin_only.rb.
  module TurboStreamsAdminOnly
    def subscribed
      return reject unless current_user.respond_to?(:admin?) && current_user.admin?

      super
    end
  end
end
