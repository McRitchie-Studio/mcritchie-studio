class LandingController < ApplicationController
  def index
    # Google sign-in always lands here. A visitor who pressed Build My App
    # signed out goes on to that launch (BuildController#launch, which takes the
    # press from the session); one who only started a /build draft while
    # signed out is sent back to it, once.
    return unless logged_in?

    if (pending = BuildIntake::PendingLaunch.pending_token(session))
      session.delete(:build_draft_token)
      return redirect_to(build_request_launch_path(pending))
    end
    token = session[:build_draft_token]
    return unless token

    session.delete(:build_draft_token)
    redirect_to build_request_path(token) if AppRequest.exists?(token: token)
  end

  def terms
  end

  def privacy
  end

  def about
  end
end
