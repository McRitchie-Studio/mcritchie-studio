# /build — the McRitchie Studio app funnel. A visitor describes an app, signs
# in, claims a free <name>.mcritchie.studio, and the build is queued for an
# agent. Nothing is generated here; builds are asynchronous.
#
#   GET   /build                   the prompt
#   POST  /build                   send the prompt → a draft (no account needed)
#   GET   /build/check?subdomain=  live availability, JSON
#   GET   /build/requests          admin: every requested app, filterable by status
#   GET   /build/:token            the draft: sign in, then claim a subdomain;
#                                  once queued, the request's status page
#   PATCH /build/:token            claim the subdomain and queue the build
class BuildController < ApplicationController
  skip_before_action :require_authentication, only: %i[new create show check]
  before_action :load_request, only: %i[show update]
  before_action :require_admin, only: :index

  # A public form that writes a row: bounded, so it cannot be used to fill the table.
  rate_limit to: 10, within: 1.minute, only: :create, with: -> { redirect_to build_path, alert: "Too many requests — try again in a minute." }
  rate_limit to: 60, within: 1.minute, only: :check

  # Every app requested through the funnel, newest first. ?status= narrows it;
  # the default hides drafts (a prompt whose sender never signed in) behind
  # their own tab so the list leads with real requests.
  def index
    @counts = AppRequest.group(:status).count
    @status = params[:status].presence_in(AppRequest::STATUSES + [ "all" ]) || "active"
    scope = AppRequest.includes(:user).recent
    @requests = case @status
                when "all" then scope
                when "active" then scope.where(status: AppRequest::HOLDING)
                else scope.where(status: @status)
                end
  end

  def new
    @draft = logged_in? ? AppRequest.where(user: current_user, status: "draft").recent.first : nil
  end

  def create
    request_row = AppRequest.new(prompt: params.dig(:app_request, :prompt), user: (current_user if logged_in?))
    unless request_row.save
      message = request_row.errors.full_messages.to_sentence
      respond_to do |format|
        format.json { render json: { error: message }, status: :unprocessable_entity }
        format.html { redirect_to build_path, alert: message }
      end
      return
    end

    # Kept for Google sign-in, which always lands on the home page: the home
    # page forwards a just-signed-in visitor here once (LandingController).
    session[:build_draft_token] = request_row.token unless logged_in?
    respond_to do |format|
      # The composer asks for JSON when the visitor is signed out: it stays on
      # the page and opens the sign-in modal, whose emailed link returns to `path`.
      format.json { render json: { token: request_row.token, path: build_request_path(request_row.token) }, status: :created }
      format.html { redirect_to build_request_path(request_row.token) }
    end
  end

  def show
    return unless logged_in? && @app_request.draft?

    unless @app_request.claimable_by?(current_user)
      redirect_to build_path, alert: "That draft belongs to another account."
      return
    end
    @app_request.update!(user: current_user) if @app_request.user.nil?
    session.delete(:build_draft_token)
  end

  def update
    unless logged_in? && @app_request.claimable_by?(current_user) && @app_request.draft?
      redirect_to build_request_path(@app_request.token)
      return
    end
    @app_request.user ||= current_user
    @app_request.queue!(params.dig(:app_request, :subdomain))
    redirect_to build_request_path(@app_request.token), notice: "Your app is in the build queue."
  rescue ActiveRecord::RecordInvalid => e
    @app_request.status = "draft"
    @app_request.errors.merge!(e.record.errors) unless e.record.equal?(@app_request)
    flash.now[:alert] = @app_request.errors.full_messages.to_sentence.presence || e.message
    render :show, status: :unprocessable_entity
  end

  def check
    reason = AppRequest.unavailable_reason(params[:subdomain])
    render json: { subdomain: AppRequest.normalize_subdomain(params[:subdomain]), available: reason.nil?, reason: reason }
  end

  private

  def load_request
    @app_request = AppRequest.find_by(token: params[:token])
    return redirect_to(build_path, alert: "That build request was not found.") if @app_request.nil?

    # Once a request belongs to someone, only they (or an admin) may open it.
    owner = @app_request.user
    return if owner.nil? || (logged_in? && (owner == current_user || current_user.admin?))

    redirect_to build_path, alert: "That build request belongs to another account."
  end
end
