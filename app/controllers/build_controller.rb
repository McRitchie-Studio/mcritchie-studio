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
#   PATCH /build/:token            Build my app: claim the subdomain and queue;
#                                  from the summary card, the launch panel
#                                  (build/_launch) in place, then the CTO's chat
#   GET   /build/launch-demo/:slug development only, admin: replay that panel
#
# WHO MAY USE A DRAFT is whoever holds its secret token until it belongs to an
# account, then that account (or an admin, to read). load_request is the gate
# for every action that names a token.
class BuildController < ApplicationController
  before_action :load_request, only: %i[show update message turns choose]
  before_action :require_admin, only: %i[index launch_demo]

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
  # The summary card's own DOM id (build/cards/_summary), the target of a
  # refused launch's stream.
  def self.summary_dom_id(message) = "build-summary-#{message.id}"
  # A successful Build My App swaps the whole agent shell (the one on the page,
  # whichever page drew it) for the launch panel, build/_launch, whose id is LAUNCH_ID.
  LAUNCH_TARGETS = "[data-agent-shell]".freeze
  LAUNCH_ID = "build-launch".freeze
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
  #
  # A REFUSAL from the summary card (Turbo, carrying its message_id) answers ON
  # that card: a Turbo Stream redraws it with the reason and a next step
  # (refuse_launch). Never a 422 page: Turbo renders a failed form's page as a
  # same-URL refresh, which this page morphs (turbo_refreshes_with :morph), and
  # the morph strips Alpine's display:none from every x-show it touches. On
  # 2026-10-18 that opened the Links drawer and dropped the reason (task
  # build-launch-chat-growth).
  def update
    unless logged_in? && @app_request.claimable_by?(current_user) && @app_request.draft?
      redirect_to build_request_path(@app_request.token)
      return
    end
    name = params.dig(:app_request, :subdomain).presence || @app_request.subdomain
    unless @app_request.intake_complete? || current_user.admin?
      return refuse_launch("Finish the steps first.") do
        redirect_to build_request_path(@app_request.token), alert: "Finish the steps first.", status: :see_other
      end
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
    respond_to do |format|
      # The summary card's Turbo press (task build-launch-handoff): the launch
      # has ALREADY happened above; what follows is presentation. The agent
      # shell is swapped in place for the launch panel (build/_launch: the new
      # CTO's portrait, the app's name, three steps in the app's colours), and
      # the address moves to the CTO's chat at once, so a reload mid-animation
      # lands there. app/javascript/build_launch.js plays the steps, then visits
      # the chat. A refusal never reaches here (refuse_launch, below).
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace_all(LAUNCH_TARGETS, partial: "build/launch", locals: launch_locals(launch.app_cto)),
          helpers.turbo_stream_action_tag(:replace_url, target: LAUNCH_ID, url: chat_application_path(launch.app.slug))
        ]
      end
      format.any do
        redirect_to chat_application_path(launch.app.slug), status: :see_other,
                                                            notice: "#{launch.app_cto.name} is your CTO. Say hello."
      end
    end
  rescue AppLaunch::Incomplete => e
    refuse_launch(e.message) { redirect_to build_request_path(@app_request.token), alert: e.message, status: :see_other }
  rescue ActiveRecord::RecordInvalid => e
    @app_request.status = "draft"
    @app_request.errors.merge!(e.record.errors) unless e.record.equal?(@app_request)
    # The address's and the plan's errors read as sentences of their own ("That
    # name is taken."), not "Subdomain That name is taken.".
    reason = @app_request.errors.map { |error| %i[base subdomain].include?(error.attribute) ? error.message : error.full_message }
                                .uniq.to_sentence.presence || e.message
    plan_limit = @app_request.errors.added?(:base, :apps_per_account)
    domain = @app_request.errors.include?(:subdomain)
    refuse_launch(reason, plan_limit: plan_limit, domain: domain) do
      flash.now[:alert] = reason
      load_chat
      render :show, status: :unprocessable_entity
    end
  end

  # Development only (the route exists only there), for an admin: the launch
  # panel for an app that has already launched, on its own page, so the
  # animation and its hand-off to the CTO's chat can be watched again without
  # launching another app. GET /build/launch-demo/:slug.
  def launch_demo
    app_cto = AppCto.includes(:app).find_by(app_slug: params[:slug].to_s)
    return redirect_to(build_requests_path, alert: "No client app named #{params[:slug]}.") unless app_cto

    @launch_locals = launch_locals(app_cto)
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

  # A refused Build My App. From the summary card's Turbo form: the card
  # redrawn with the reason and a next step (build/cards/_summary `refusal`),
  # 422. Without a card to name (an old page, a plain form): the composer shows
  # the reason. Any other format runs the block (the old redirect or page).
  def refuse_launch(reason, plan_limit: false, domain: false, &html)
    respond_to do |format|
      format.turbo_stream do
        @app_request.reload
        card = summary_message
        stream = if card
                   refusal = { reason: reason, plan_limit: plan_limit, domain: domain,
                               existing_app: (existing_app_path if plan_limit) }
                   turbo_stream.replace(BuildController.summary_dom_id(card), partial: "build/cards/summary",
                                        locals: { card: card.intake_card, message: card, request_row: @app_request, refusal: refusal })
                 else
                   replace_form(error: reason)
                 end
        render turbo_stream: stream, status: :unprocessable_content
      end
      format.any(&html)
    end
  end

  # The launch panel's locals (build/_launch): the CTO the launch made, its app,
  # and the chat the panel hands over to.
  def launch_locals(app_cto)
    { app_cto: app_cto, cto: AppOwnership.cto_for_app(app_cto.app_slug), href: chat_application_path(app_cto.app_slug) }
  end

  # The summary card the press came from (its form's message_id), in this thread.
  def summary_message
    id = params[:message_id].to_s[/\A\d{1,18}\z/]
    return nil unless id

    row = AgentMessage.find_by(id: id, channel: "web", thread_key: BuildIntake.thread_key(@app_request.token))
    row if row&.intake_card.is_a?(Hash) && row.intake_card["card"] == "summary"
  end

  # Where the plan-limit refusal sends an owner: the chat of the app they
  # already hold on this tier (newest), else that request's page.
  def existing_app_path
    other = AppRequest.holding.where(user: current_user, tier: @app_request.tier).where.not(id: @app_request.id).order(created_at: :desc).first
    return nil unless other

    if other.subdomain.present? && App.exists?(slug: other.subdomain) && AppOwnership.manage_app?(current_user, other.subdomain)
      chat_application_path(other.subdomain)
    else
      build_request_path(other.token)
    end
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
