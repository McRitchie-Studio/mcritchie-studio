# /applications/:slug/chat: a live chat with the app's CTO, for the app's owner
# or an admin (docs/agents/system/agent-message-loop.md, "Web chat"; the plan is
# Phase 7 step 3 of .agents/epics/domain-agents.md). The views are the shared
# agent chat (app/views/agent_chats); this controller supplies the CTO and its thread.
#
#   show    a newly launched app's FIRST visit by its owner (AppCto
#           launch_animation_pending, task build-sign-in-modal): the launch
#           animation (build/_launch), which then visits this same page; else
#           the user's own thread with this app's CTO (newest WebChat::HISTORY
#           turns) under the app's status card: its Building · Releasing ·
#           Deploying with the open tasks in each and the newest few listed
#           (AppDevopsStages.board_for: an admin's titles link to the board, an
#           owner's are plain and sanitized) and the tokens used (never
#           dollars), then the form. The
#           page subscribes to its Turbo stream through CtoChatChannel, so the
#           typing indicator and the answer arrive without a reload
#   status  the card's pills and task list alone, the frame the page reloads
#           when a task for the app moves (AppDevopsStages::Live)
#   create  one message: AgentMessages::WebIngest stores it as a `web`
#           AgentMessage for this app's CTO, and the dispatcher answers it as it
#           answers Discord. Answers with the new turn as a Turbo Stream. The
#           message may carry files the composer uploaded first
#           (CtoChatAttachmentsController, AgentMessages::Attachments). A
#           nameless owner's answer to the CTO's first-name ask saves the name
#           (AgentMessages::FirstNameAsk); these pages never open the engine's
#           first-name modal
#   avatars "New set" in the owner's avatar picker (cto_chats/_avatar_picker;
#           CtoAnimalSet): the next set of animals in the app's palette
#   avatar  the owner's pick from that picker (task cto-animal-avatar-bank):
#           saves AppCto#portrait (an animal, or a portrait key the app already
#           had) and the launching request's cto_avatar, then reloads the chat,
#           so the head, the typing pulse and the being-built page all show it.
#           An avatar ask in the chat opens it (AgentMessages::AvatarAsk)
#
# Past the AdminWall (SIGNED_IN), every action answers 404, never 403, unless the viewer
# owns the app or is an admin, exactly as the app's own page does; avatar and
# avatars answer 404 to an admin who does not own the app too (the look is the
# owner's to pick). The CTO is the
# app's, from config/cto_reports.yml: nothing the request carries picks the soul.
class CtoChatsController < ApplicationController
  include CtoAnimalSet
  FORM_ID = "cto-chat-form".freeze

  before_action :load_app_and_cto
  before_action :require_avatar_owner, only: %i[avatar avatars]
  # The CTO asks a nameless owner for their first name in the chat
  # (AgentMessages::FirstNameAsk), so the engine's first-name modal never opens
  # over the launch panel or the thread (Alex McRitchie 2026-10-19).
  before_action :skip_first_name_modal!
  helper_method :composer_locals

  def show
    return if play_launch_animation

    @available = AgentMessages::WebIngest.available?(@cto)
    @messages = AgentMessages::WebChat.history(@app.slug, current_user.id)
    @meter = AgentUsage.chat_meter(@app, user: current_user, soul: @cto.soul).without_cost
    @stream = AgentMessages::WebChat.stream_name(@app.slug, current_user.id)
    @answered = answered?
    @admin = AppOwnership.admin?(current_user)
    @board = AppDevopsStages.board_for(@app, admin: @admin)
    @avatar_owner = avatar_owner?
  end

  def avatars
    render_animal_set(@app_cto.palette)
  end

  # The picker saves with fetch (build_chat.js#saveAvatar, Accept JSON): the
  # answer carries the head's new portrait, drawn here, and the line a screen
  # reader hears; a refusal or a failure carries `error`, which the picker
  # shows in its own status line. Without JavaScript the form posts as HTML
  # and lands back on the chat. The write is logged on failure
  # (rescue_and_log, docs/agents/modules/backend-discipline.md) and answered,
  # never a bare 500.
  def avatar
    pick = params[:portrait].to_s
    return avatar_refused("Pick one of the avatars.", :unprocessable_entity) unless BuildIntake::Portraits.choosable?(pick)

    begin
      rescue_and_log(target: @app_cto, parent: @app) do
        AppCto.transaction do
          @app_cto.update!(portrait: pick)
          AppRequest.holding.where(subdomain: @app.slug).update_all(cto_avatar: pick, updated_at: Time.current)
        end
      end
    rescue StandardError
      return avatar_refused("The new look did not save. Try again in a moment.", :internal_server_error)
    end

    message = "Saved. #{@app_cto.name}'s new look: #{helpers.cto_avatar_label(pick)}."
    respond_to do |format|
      format.json do
        render json: { ok: true, avatar: pick, message: message,
                       portrait_html: render_to_string(partial: "applications/cto_avatar", formats: [ :html ],
                                                       locals: { cto: @cto, size: "xl" }) }
      end
      format.html { redirect_to chat_application_path(@app.slug), notice: message, status: :see_other }
    end
  end

  # The status card's live half alone (agent_chats/_devops_stages, a turbo-frame),
  # which the page fetches when AppDevopsStages::Live says a task for the app moved.
  def status
    admin = AppOwnership.admin?(current_user)
    render partial: "agent_chats/devops_stages",
           locals: { app: @app, board: AppDevopsStages.board_for(@app, admin: admin), admin: admin }
  end

  def create
    outcome = rescue_and_log(target: @app) do
      AgentMessages::WebIngest.new(user: current_user, cto: @cto)
                              .call(params.dig(:cto_chat, :text), client_id: params.dig(:cto_chat, :client_id),
                                    attachments: attachment_tokens)
    rescue AgentMessages::WebIngest::Refused => e
      e
    end
    return refused(outcome) if outcome.is_a?(AgentMessages::WebIngest::Refused)

    # A skip of the CTO's first-name ask (AgentMessages::FirstNameAsk) is the
    # engine's skip: not now, for this session, so no other page asks either.
    session[Studio::FIRST_NAME_SKIP_SESSION_KEY] = true if outcome.run_meta.is_a?(Hash) && outcome.run_meta["first_name"] == "skipped"

    AgentMessages::WebChat.broadcast_turn(outcome, append: true) if outcome.previously_new_record?
    respond_to do |format|
      format.turbo_stream { render turbo_stream: [ append_turn(outcome), replace_form ] }
      format.html { redirect_to chat_application_path(@app.slug), status: :see_other }
    end
  end

  private

  # The app's initial load (task build-sign-in-modal, Alex McRitchie 2026-10-19): the
  # owner's first visit after Build My App, however they arrived (the signed-in
  # press, the magic link's landing, Google's), plays the launch panel
  # (build/_launch: three steps in the app's colours, then a visit back here).
  # The flag is cleared HERE, as the panel renders, so a refresh goes straight
  # to the chat. Only an owner of the app clears it: an admin reading someone
  # else's app sees the chat and leaves the owner's first visit alone. Turbo's
  # hover prefetch (X-Sec-Purpose: prefetch) must not spend it on a page nobody
  # opened, so it gets an empty answer; a click on that link then loads the page
  # in full, which plays the panel. True when it answered.
  def play_launch_animation
    app_cto = @cto.app_cto
    return false unless app_cto&.launch_animation_pending?
    return false unless AppMembership.owners.exists?(app_slug: @app.slug, user_slug: current_user.slug)

    if request.headers["X-Sec-Purpose"] == "prefetch"
      head :no_content
      return true
    end
    return false unless app_cto.take_launch_animation!

    response.headers["Cache-Control"] = "no-store"
    @launch_locals = { app_cto: app_cto, cto: @cto, href: chat_application_path(@app.slug) }
    render :launch
    true
  end

  # The composer's upload tokens (CtoChatAttachmentsController#create), strings only.
  def attachment_tokens
    raw = params.dig(:cto_chat, :attachments)
    raw.is_a?(Array) ? raw.select { |t| t.is_a?(String) } : []
  end

  def refused(error)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: replace_form(error: error.message, text: params.dig(:cto_chat, :text).to_s,
                                          tokens: attachment_tokens),
               status: :unprocessable_content
      end
      format.html { redirect_to chat_application_path(@app.slug), alert: error.message, status: :see_other }
    end
  end

  def append_turn(message)
    turbo_stream.append(AgentMessages::WebChat::MESSAGES_TARGET, partial: "agent_chats/turn",
                                                                 locals: { message: message, agent_name: @cto.display_name })
  end

  def replace_form(error: nil, text: "", tokens: [])
    turbo_stream.replace(FORM_ID, partial: "agent_chats/form",
                                  locals: composer_locals(error: error, text: text, tokens: tokens)
                                    .merge(agent_name: @cto.display_name))
  end

  # The shared composer's locals (agent_chats/_form) for this app's CTO chat.
  # `attachments` fills the form's attachments slot: where files upload, and the
  # files a REFUSED send carried (`tokens`), re-rendered as ready chips so the
  # owner fixes the message without attaching them again.
  def composer_locals(error: nil, text: "", tokens: [])
    { url: chat_application_path(@app.slug), scope: :cto_chat, id: FORM_ID, error: error, text: text,
      attachments: attachments_locals(tokens) }
  end

  # The attachments slot's locals, or nil (no Attach at all) while chat files
  # are off (AgentMessages::Attachments.enabled?: the private bucket has no keys).
  def attachments_locals(tokens)
    return nil unless AgentMessages::Attachments.enabled?

    { upload_url: chat_attachments_application_path(@app.slug),
      held: AgentMessages::Attachments.held(tokens, app_slug: @app.slug, user: current_user) }
  end

  # Whether the agents answer this user's messages HERE now
  # (config/agent_answerers.yml), read without creating a person: their role,
  # or the app-owner rule on this app's thread (Answerers#app_owner_thread?). A
  # user with no person yet is answered here only as this app's owner: their
  # first message makes a public person linked to their user, which the rule
  # answers on this thread.
  def answered?
    answerers = AgentMessages::Answerers.current
    person = AgentMessages::WebIngest.existing_person(current_user)
    return answerers.app_owner_user?(current_user, app_slug: @app.slug, soul: @cto.soul) if person.nil?

    probe = AgentMessage.new(channel: "web", channel_ref: @app.slug, soul_slug: @cto.soul,
                             thread_key: AgentMessages::WebChat.thread_key(@app.slug, current_user.id))
    answerers.allowed?(person, message: probe)
  end

  def avatar_refused(error, status)
    respond_to do |format|
      format.json { render json: { ok: false, error: error }, status: status }
      format.html { redirect_to chat_application_path(@app.slug), alert: error, status: :see_other }
    end
  end

  # The app's owner (AppMembership), with a client CTO row to dress.
  def avatar_owner?
    @cto.client? && @cto.app_cto.present? &&
      AppMembership.owners.exists?(app_slug: @app.slug, user_slug: current_user.slug)
  end

  def require_avatar_owner
    raise ActiveRecord::RecordNotFound, "not the owner" unless avatar_owner?

    @app_cto = @cto.app_cto
  end

  def load_app_and_cto
    @app = App.find_by(slug: params[:slug])
    raise ActiveRecord::RecordNotFound, "no such app" unless @app && AppOwnership.manage_app?(current_user, @app.slug)

    @cto = AppOwnership.cto_for_app(@app.slug)
    raise ActiveRecord::RecordNotFound, "no CTO" unless @cto
  end
end
