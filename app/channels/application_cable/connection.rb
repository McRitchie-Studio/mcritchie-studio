module ApplicationCable
  # /cable admits any SIGNED-IN user with a current session; what they may hear
  # is each channel's own check, made at subscribe:
  #
  #   Turbo::StreamsChannel  admins only (TurboStreamsAdminOnly, below). Every
  #                          stream it carries (the deployments board, the
  #                          activity feed) is ops HTML behind the admin wall
  #                          (app/controllers/concerns/admin_wall.rb). A signed
  #                          Turbo stream name never expires, so a name saved
  #                          while those pages were public would otherwise keep
  #                          streaming board HTML to whoever holds it.
  #   CtoChatChannel         the one user a CTO web chat stream names, while they
  #                          may manage that app (app owners are not admins).
  #
  # Until the CTO web chat (2026-10-16) the connection itself refused non-admins.
  # A channel added later must make its own check: ApplicationCable::Channel
  # refuses a non-admin unless the channel overrides `authorized?`.
  #
  # The user is read from the session cookie exactly as the engine's controller
  # auth reads it (Studio::ErrorHandling#current_user and #verify_session_token):
  # session[Studio.session_key] names the user, and session[:session_token] must
  # match the user's rotating token (OPSEC-045), so a revoked session cannot keep a
  # socket the page itself would refuse.
  #
  # CONNECT IS THE ONLY CHECK, so a revocation must close the sockets it revokes.
  # `Connection.disconnect(user)` does that: User calls it after commit when the
  # token rotates, admin is lost, or the row is destroyed, and the hub's
  # clear_app_session calls it on sign-out (/tasks/cable-drops-revoked-sockets).
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    # Drops every open /cable socket identified as `user`, on every dyno.
    #
    # The message goes out on the connection's internal channel through the
    # server's pubsub adapter, so with the Redis adapter (config/cable.yml) it
    # reaches sockets held by any web dyno, and a rake task, console or job can
    # send it too. It asks the client to RECONNECT, and reconnecting re-runs
    # `connect`: a session that is still valid is back in a second, a revoked one
    # is rejected. That is why over-disconnecting (a sign-out drops the user's
    # other tabs for a moment) is safe and under-disconnecting is the leak.
    #
    # Never raises. It runs after a write has committed, so a Redis outage must
    # not turn a durable rotation into a 500; the failure goes to ErrorLog.
    def self.disconnect(user)
      return if user.nil?

      ActionCable.server.remote_connections.where(current_user: user).disconnect(reconnect: true)
    rescue StandardError => e
      Rails.logger.error("[cable] disconnect failed for user_id=#{user&.id}: #{e.class}: #{e.message}")
      begin
        ErrorLog.capture!(e)
      rescue StandardError
        nil
      end
    end

    def connect
      self.current_user = user_from_session || reject_unauthorized_connection
    end

    private

    def user_from_session
      session = request.session
      user_id = session[Studio.session_key.to_s] || session[Studio.session_key]
      return nil if user_id.blank?

      user = User.find_by(id: user_id)
      return nil if user.nil?
      return nil unless session_token_current?(user, session)

      user
    end

    def session_token_current?(user, session)
      return true unless user.respond_to?(:session_token)

      cookie_token = session["session_token"] || session[:session_token]
      user.session_token.present? && ActiveSupport::SecurityUtils.secure_compare(user.session_token, cookie_token.to_s)
    end
  end
end
