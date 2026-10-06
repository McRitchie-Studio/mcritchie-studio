module ApplicationCable
  # /cable admits admins only. Every stream the hub broadcasts (the deployments
  # board, the activity feed) carries ops HTML, and every page that subscribes to
  # one sits behind the admin wall (app/controllers/concerns/admin_wall.rb). A
  # signed Turbo stream name never expires, so a name saved while those pages were
  # public would otherwise keep streaming board HTML to whoever holds it.
  #
  # The user is read from the session cookie exactly as the engine's controller
  # auth reads it (Studio::ErrorHandling#current_user and #verify_session_token):
  # session[Studio.session_key] names the user, and session[:session_token] must
  # match the user's rotating token (OPSEC-045), so a revoked session cannot keep a
  # socket the page itself would refuse.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = admin_from_session || reject_unauthorized_connection
    end

    private

    def admin_from_session
      session = request.session
      user_id = session[Studio.session_key.to_s] || session[Studio.session_key]
      return nil if user_id.blank?

      user = User.find_by(id: user_id)
      return nil unless user&.admin?
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
