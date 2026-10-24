class LandingController < ApplicationController
  def index
    # Google sign-in always lands here. A visitor who pressed Build My App
    # signed out goes on to that launch (BuildController#launch, which takes the
    # press from the session); one who only started a /build draft while
    # signed out is sent back to it, once.
    return unless logged_in?

    if (pending = BuildIntake::PendingLaunch.pending_token(session))
      session.delete(:build_draft_token)
      return redirect_to(build_request_launch_path(pending)) if launchable_draft?(pending)

      # A draft deleted, launched, or claimed by someone else since the press:
      # forget the press, so the home page never bounces to /build for it.
      BuildIntake::PendingLaunch.clear(session)
      return
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

  private

  # A draft the signed-in visitor's press can still launch: it exists, is still
  # a draft, and has no account or theirs (AppRequest#claimable_by?, as a query).
  def launchable_draft?(token)
    AppRequest.where(token: token, status: "draft", user_id: [ nil, current_user.id ]).exists?
  end
end
