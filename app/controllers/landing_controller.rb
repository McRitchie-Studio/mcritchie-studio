class LandingController < ApplicationController
  skip_before_action :require_authentication

  def index
    # Google sign-in always lands here. A visitor who started a /build draft
    # while signed out is sent back to it, once.
    token = session[:build_draft_token]
    return unless token && logged_in?

    session.delete(:build_draft_token)
    redirect_to build_request_path(token) if AppRequest.exists?(token: token)
  end

  def terms
  end

  def privacy
  end
end
