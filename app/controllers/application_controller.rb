class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  allow_browser versions: :modern

  # OPSEC-045: clear a stale/forced-out session before anything reads
  # current_user, and populate Current.user for the request lifecycle. Both
  # helpers live here until every deployed app is on a studio-engine release
  # that ships them.
  before_action :verify_session_token
  before_action :set_current_context

  private

  def set_app_session(user)
    session[Studio.session_key] = user.id

    if user.respond_to?(:session_token)
      if user.session_token.blank? && user.respond_to?(:update_column)
        user.update_column(:session_token, SecureRandom.hex(32))
      end
      session[:session_token] = user.session_token
    end

    session.delete(:onchain)

    if session[:sso_source].blank? || session[:sso_source] == Studio.app_name
      session[:sso_email]    = user.email
      session[:sso_name]     = user.try(:name)
      session[:sso_provider] = user.provider
      session[:sso_uid]      = user.uid
      session[:sso_wallet]   = user.try(:solana_address)
      session[:sso_source]   = Studio.app_name
      session[:sso_logo]     = Studio.sso_logo
    end
  end

  def clear_app_session
    session.delete(Studio.session_key)
    session.delete(:session_token)
    session.delete(:onchain)

    return unless session[:sso_source] == Studio.app_name

    session.delete(:sso_email)
    session.delete(:sso_name)
    session.delete(:sso_provider)
    session.delete(:sso_uid)
    session.delete(:sso_wallet)
    session.delete(:sso_source)
    session.delete(:sso_logo)
  end

  def set_current_context
    Current.user = current_user if defined?(Current) && logged_in?
  rescue StandardError
    nil
  end

  def verify_session_token
    return unless logged_in?
    return unless current_user.respond_to?(:session_token)

    user_token = current_user.session_token
    cookie_token = session[:session_token]
    return if user_token.present? && user_token == cookie_token

    Rails.logger.info("[opsec-045] session_token mismatch user_id=#{current_user.id} - forcing re-login")
    @current_user = nil
    clear_app_session

    respond_to do |format|
      format.html { redirect_to login_path, alert: "Your session expired. Please sign in again." }
      format.json { render json: { error: "session expired" }, status: :unauthorized }
      format.any { head :unauthorized }
    end
  end
end
