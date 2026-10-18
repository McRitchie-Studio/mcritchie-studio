# /build — the McRitchie Studio app funnel, as a chat with Ray
# (.agents/epics/build-with-xan-design.md, build-with-ray-v2.md; BuildIntake). A
# visitor tells Ray what they want to build; Ray asks for the idea, a CTO, colors
# and an address, one card at a time, and the visitor's taps fill the status
# card. Build my app asks for sign-in only then, claims the subdomain and queues
# the build for an agent. Nothing is generated here; builds are asynchronous.
# Every page is the agent shell (app/views/agent_chats/_shell.html.erb).
#
#   GET   /build                   the opening question
#   POST  /build                   the first message → a draft and Ray's thread
#                                  (no account needed; bot-shielded). From the
#                                  page it answers IN PLACE: Turbo Streams swap
#                                  the empty thread for the draft's chat and
#                                  move the address to /build/:token
#   GET   /build/check?subdomain=  live availability, JSON
#   GET   /build/requests          admin: every requested app, filterable by status
#   GET   /build/:token            a draft: the chat with Ray under its status card;
#                                  once queued, the request's status page
#   POST  /build/:token/messages   one more message to Ray
#   GET   /build/:token/turns      the poll: pending turns and the status card,
#                                  as Turbo Streams (no /cable socket signed out)
#   PATCH /build/:token/intake     a tap on an intake card (BuildIntake::Choice):
#                                  sets the field and relays the visitor's turn
#   PATCH /build/:token            Build my app: claim the subdomain and queue
#
# WHO MAY USE A DRAFT is whoever holds its secret token until it belongs to an
# account, then that account (or an admin, to read). load_request is the gate
# for every action that names a token.
class BuildController < ApplicationController
  before_action :load_request, only: %i[show update message turns choose]
  before_action :require_admin, only: :index

  # Public forms that write rows: bounded per IP, so they cannot fill a table or
  # run up the agents' bill (BuildIntake::Caps bounds the answers themselves).
  rate_limit to: 10, within: 1.minute, only: :create, with: -> { redirect_to build_path, alert: "Too many requests — try again in a minute." }
  rate_limit to: 12, within: 1.minute, only: :message, with: -> { head :too_many_requests }
  rate_limit to: 30, within: 1.minute, only: :choose, with: -> { head :too_many_requests }
  rate_limit to: 120, within: 1.minute, only: :turns, with: -> { head :too_many_requests }
  rate_limit to: 60, within: 1.minute, only: :check

  # The first message's browser proof (BrowserProof, the /contact defence): a
  # signed render time the page's script writes in. A person types an idea in
  # more than two seconds; an example chip still takes a click and a send.
  PROOF_PURPOSE = :build_chat
  PROOF_MIN_SECONDS = 2
  # The answers the page asks the poll about at most, newest first.
  POLL_LIMIT = 10
  FORM_ID = "build-chat-form".freeze
  FIRST_FORM_ID = "build-first-form".freeze
  # /build's "Built with McRitchie Studio" gallery: shown only before the first
  # message. The first message's stream removes it, as /build/<token> has none.
  GALLERY_ID = "build-gallery".freeze
  # The region the first message swaps in place (build/_chat), and the status
  # card's stream target (build/_status_card; the id predates the card).
  CHAT_ID = "build-chat-page".freeze
  STATUS_ID = "build-checklist".freeze
  # The intake agent as the page names it. The soul slug stays BuildIntake.soul.
  AGENT_NAME = "Ray".freeze
  AGENT_ROLE = "AI build agent".freeze

  # Every app requested through the funnel, newest first. ?status= narrows it;
  # the default hides drafts (a prompt whose sender never signed in) behind
  # their own tab so the list leads with real requests.
  def index
    @counts = AppRequest.group(:status).count
    @showcase_count = AppRequest.where(showcase: true).count
    @status = params[:status].presence_in(AppRequest::STATUSES + %w[all showcase]) || "active"
    scope = AppRequest.includes(:user).recent
    @requests = case @status
                when "all" then scope
                when "active" then scope.where(status: AppRequest::HOLDING)
                when "showcase" then scope.where(showcase: true)
                else scope.where(status: @status)
                end
  end

  def new
    # A reader who came from an email: an app request made now is credited
    # to it (EmailEvents::Results).
    session[:email_ref] = params[:ref] if params[:ref].is_a?(String) && params[:ref].match?(/\A[\w-]{16,64}\z/)
    @intake_agent = Agent.find_by(slug: BuildIntake.soul)
    @examples = BuildGallery.examples
  end

  def create
    # A bot that fills the hidden field gets the page back, and nothing is stored.
    return redirect_to(build_path, status: :see_other) if params.dig(:app_request, BrowserProof::HONEYPOT_FIELD).present?

    text = params.dig(:app_request, :prompt)
    request_row = AppRequest.new(prompt: text, user: (current_user if logged_in?))
    saved = rescue_and_log(target: request_row) do
      AppRequest.transaction do
        next false unless request_row.save

        BuildIntake::Ingest.new(request: request_row, user: (current_user if logged_in?), ip: request.remote_ip)
                           .call(text, client_id: params.dig(:app_request, :client_id), bot_reason: bot_reason)
        true
      end
    rescue BuildIntake::Ingest::Refused => e
      request_row.errors.add(:prompt, e.message)
      false
    end
    unless saved
      message = request_row.errors.full_messages.to_sentence
      respond_to do |format|
        format.json { render json: { error: message }, status: :unprocessable_entity }
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(FIRST_FORM_ID, partial: "build/first_form",
                                                                   locals: { error: message, text: text.to_s }),
                 status: :unprocessable_content
        end
        format.html { redirect_to build_path, alert: message }
      end
      return
    end

    # Kept for Google sign-in, which always lands on the home page: the home
    # page forwards a just-signed-in visitor here once (LandingController).
    session[:build_draft_token] = request_row.token unless logged_in?
    # Credited once, then forgotten: a later visitor on the same browser is
    # not this email's reader.
    EmailEvents::Results.record!(session.delete(:email_ref), "requested_app", source: "app") if session[:email_ref]
    respond_to do |format|
      format.json { render json: { token: request_row.token, path: build_request_path(request_row.token) }, status: :created }
      # The page's own post: the conversation starts HERE. The empty thread
      # becomes the draft's chat (its first turn already pending, so the poll
      # starts), the status slot is redrawn for the draft, the gallery goes (a
      # reload of /build/<token> has none), and replace_url
      # (app/javascript/build_shell.js) moves the address bar without a reload.
      format.turbo_stream do
        @app_request = request_row
        load_chat
        render turbo_stream: [
          turbo_stream.replace(CHAT_ID, partial: "build/chat", locals: { request_row: request_row, messages: @messages }),
          replace_checklist,
          turbo_stream.remove(GALLERY_ID),
          helpers.turbo_stream_action_tag(:replace_url, target: CHAT_ID, url: build_request_path(request_row.token))
        ]
      end
      format.html { redirect_to build_request_path(request_row.token), status: :see_other }
    end
  end

  def show
    if logged_in? && @app_request.draft?
      unless @app_request.claimable_by?(current_user)
        redirect_to build_path, alert: "That draft belongs to another account."
        return
      end
      # An admin opening an unsigned draft from /build/requests only reads it;
      # attaching it would lock the visitor out of their own chat. Anyone else
      # signing in ADOPTS the draft and its thread with Ray.
      @app_request.update!(user: current_user) if @app_request.user.nil? && !current_user.admin?
      session.delete(:build_draft_token)
    end
    @app_request.draft? ? load_chat : (@intake_agent = Agent.find_by(slug: BuildIntake.soul))
  end

  # One more message to Ray, from the chat's composer.
  def message
    return redirect_to(build_request_path(@app_request.token), status: :see_other) unless @app_request.draft?

    outcome = rescue_and_log(target: @app_request) do
      BuildIntake::Ingest.new(request: @app_request, user: (current_user if logged_in?), ip: request.remote_ip)
                         .call(params.dig(:build_chat, :text), client_id: params.dig(:build_chat, :client_id))
    rescue BuildIntake::Ingest::Refused => e
      e
    end
    if outcome.is_a?(BuildIntake::Ingest::Refused)
      return respond_to do |format|
        format.turbo_stream do
          render turbo_stream: replace_form(error: outcome.message, text: params.dig(:build_chat, :text).to_s),
                 status: :unprocessable_content
        end
        format.html { redirect_to build_request_path(@app_request.token), alert: outcome.message, status: :see_other }
      end
    end

    respond_to do |format|
      format.turbo_stream { render turbo_stream: [ append_turn(outcome), replace_form ] }
      format.html { redirect_to build_request_path(@app_request.token), status: :see_other }
    end
  end

  # The page's poll while an answer is pending: the turns it names (this
  # thread's only) re-rendered, and the status card. Turbo Streams, read by
  # app/javascript/build_chat.js.
  def turns
    ids = params[:ids].to_s.split(",").filter_map { |id| id[/\A\d{1,18}\z/]&.to_i }.first(POLL_LIMIT)
    rows = AgentMessage.where(id: ids, channel: "web", thread_key: BuildIntake.thread_key(@app_request.token)).order(:id)
    streams = rows.map { |row| turbo_stream.replace("build-turn-#{row.id}", partial: "build/turn", locals: { message: row, request_row: @app_request }) }
    render turbo_stream: streams + [ replace_checklist ]
  end

  # A tap on an intake card: the only write to an intake field, and the
  # visitor's turn it relays to Ray (BuildIntake::Choice), so Ray answers with
  # the next step without the visitor typing. The stream redraws the card, adds
  # the relayed turn (pending, so the page polls for Ray's answer) and the checklist.
  def choose
    error = nil
    choice = BuildIntake::Choice.new(@app_request, user: (current_user if logged_in?), ip: request.remote_ip)
    rescue_and_log(target: @app_request) do
      choice.apply!(params[:field].to_s, params)
    rescue BuildIntake::Choice::Refused => e
      error = e.message
      @app_request.reload
    end
    card = AgentMessage.find_by(id: params[:message_id].to_s[/\A\d{1,18}\z/], channel: "web",
                                thread_key: BuildIntake.thread_key(@app_request.token))
    relay = error ? nil : choice.relay
    respond_to do |format|
      format.turbo_stream do
        streams = [ replace_checklist ]
        streams << turbo_stream.replace("build-turn-#{card.id}", partial: "build/turn", locals: { message: card, request_row: @app_request, error: error }) if card
        # Removed first: a double tap finds the turn its first tap posted (one
        # client id), and the log never shows it twice.
        streams.push(turbo_stream.remove("build-turn-#{relay.id}"), append_turn(relay)) if relay
        render turbo_stream: streams, status: error ? :unprocessable_content : :ok
      end
      format.html { redirect_to build_request_path(@app_request.token), alert: error, status: :see_other }
    end
  end

  # Build my app. Asks for sign-in (the page opens it; this answers a
  # signed-out post by sending them back), needs the whole checklist (an admin
  # may queue a showcase straight from a name), then claims and queues through
  # AppRequest#queue!, as before. client-cto-from-intake swaps what it starts.
  def update
    unless logged_in? && @app_request.claimable_by?(current_user) && @app_request.draft?
      redirect_to build_request_path(@app_request.token)
      return
    end
    name = params.dig(:app_request, :subdomain).presence || @app_request.subdomain
    unless @app_request.intake_complete? || current_user.admin?
      redirect_to build_request_path(@app_request.token), alert: "Finish the steps first.", status: :see_other
      return
    end
    @app_request.user ||= current_user
    # Build my app (AppLaunch, docs/agents/system/client-cto.md): the App, its
    # owner, its CTO and the build task in one transaction, then the page moves
    # to the new CTO's chat, where Ray's handover is already the first turn. An
    # admin's showcase without the checklist still queues the old way.
    unless @app_request.intake_complete?
      @app_request.queue!(name)
      return redirect_to(build_request_path(@app_request.token), notice: "Your app is in the build queue.")
    end

    launch = rescue_and_log(target: @app_request) { AppLaunch.new(@app_request, subdomain: name).call! }
    redirect_to chat_application_path(launch.app.slug), status: :see_other,
                                                        notice: "#{launch.app_cto.name} is your CTO. Say hello."
  rescue AppLaunch::Incomplete => e
    redirect_to build_request_path(@app_request.token), alert: e.message, status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    @app_request.status = "draft"
    @app_request.errors.merge!(e.record.errors) unless e.record.equal?(@app_request)
    flash.now[:alert] = @app_request.errors.full_messages.to_sentence.presence || e.message
    load_chat
    render :show, status: :unprocessable_entity
  end

  def check
    reason = AppRequest.unavailable_reason(params[:subdomain])
    render json: { subdomain: AppRequest.normalize_subdomain(params[:subdomain]), available: reason.nil?, reason: reason }
  end

  private

  # Why the first message looks like a bot's, or nil. A signed-in visitor has
  # already proved more than a browser.
  def bot_reason
    return nil if logged_in?

    BrowserProof.new(PROOF_PURPOSE, min_seconds: PROOF_MIN_SECONDS).reason(params.dig(:app_request, BrowserProof::PROOF_FIELD))
  end

  def load_chat
    @messages = BuildIntake.history(@app_request.token)
    @intake_agent = Agent.find_by(slug: BuildIntake.soul)
    @started = @app_request.intake_started?
  end

  def append_turn(message)
    turbo_stream.append(AgentMessages::WebChat::MESSAGES_TARGET, partial: "build/turn",
                                                                 locals: { message: message, request_row: @app_request })
  end

  def replace_form(error: nil, text: "")
    turbo_stream.replace(FORM_ID, partial: "agent_chats/form",
                                  locals: composer_locals(error: error, text: text))
  end

  # The status card (build/_status_card), redrawn by every tap, poll and first
  # message. Its target id stays build-checklist (STATUS_ID).
  def replace_checklist
    turbo_stream.replace(STATUS_ID, partial: "build/status_card",
                                    locals: { request_row: @app_request, started: @app_request.intake_started? })
  end

  helper_method :composer_locals

  # The shared composer's locals (agent_chats/_form) for this request's chat.
  def composer_locals(error: nil, text: "")
    { url: build_request_messages_path(@app_request.token), scope: :build_chat, id: FORM_ID,
      agent_name: AGENT_NAME, error: error, text: text }
  end

  def load_request
    @app_request = AppRequest.find_by(token: params[:token])
    return redirect_to(build_path, alert: "That build request was not found.") if @app_request.nil?

    # Once a request belongs to someone, only they (or an admin) may open it.
    owner = @app_request.user
    return if owner.nil? || (logged_in? && (owner == current_user || current_user.admin?))

    redirect_to build_path, alert: "That build request belongs to another account."
  end
end
