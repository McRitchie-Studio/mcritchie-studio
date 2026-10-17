# /applications/:slug/chat: a live chat with the app's CTO, for the app's owner
# or an admin (docs/agents/system/agent-message-loop.md, "Web chat"; the plan is
# Phase 7 step 3 of .agents/epics/domain-agents.md).
#
#   show    the user's own thread with this app's CTO (newest WebChat::HISTORY
#           turns), the usage meter (tokens, never dollars), and the form. The
#           page subscribes to its Turbo stream through CtoChatChannel, so the
#           typing indicator and the answer arrive without a reload
#   create  one message: AgentMessages::WebIngest stores it as a `web`
#           AgentMessage for this app's CTO, and the dispatcher answers it as it
#           answers Discord. Answers with the new turn as a Turbo Stream
#
# Past the AdminWall (SIGNED_IN), both answer 404, never 403, unless the viewer
# owns the app or is an admin, exactly as the app's own page does. The CTO is the
# app's, from config/cto_reports.yml: nothing the request carries picks the soul.
class CtoChatsController < ApplicationController
  before_action :load_app_and_cto

  def show
    @available = AgentMessages::WebIngest.available?(@cto)
    @messages = AgentMessages::WebChat.history(@app.slug, current_user.id)
    @meter = AgentUsage.meter(@app).without_cost
    @stream = AgentMessages::WebChat.stream_name(@app.slug, current_user.id)
    @answered = answered?
  end

  def create
    outcome = rescue_and_log(target: @app) do
      AgentMessages::WebIngest.new(user: current_user, cto: @cto)
                              .call(params.dig(:cto_chat, :text), client_id: params.dig(:cto_chat, :client_id))
    rescue AgentMessages::WebIngest::Refused => e
      e
    end
    return refused(outcome) if outcome.is_a?(AgentMessages::WebIngest::Refused)

    AgentMessages::WebChat.broadcast_turn(outcome, append: true) if outcome.previously_new_record?
    respond_to do |format|
      format.turbo_stream { render turbo_stream: [ append_turn(outcome), replace_form ] }
      format.html { redirect_to chat_application_path(@app.slug), status: :see_other }
    end
  end

  private

  def refused(error)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: replace_form(error: error.message, text: params.dig(:cto_chat, :text).to_s),
               status: :unprocessable_content
      end
      format.html { redirect_to chat_application_path(@app.slug), alert: error.message, status: :see_other }
    end
  end

  def append_turn(message)
    turbo_stream.append(AgentMessages::WebChat::MESSAGES_TARGET, partial: "cto_chats/turn",
                                                                 locals: { message: message, cto_name: @cto.display_name })
  end

  def replace_form(error: nil, text: "")
    turbo_stream.replace("cto-chat-form", partial: "cto_chats/form",
                                          locals: { app: @app, cto: @cto, error: error, text: text })
  end

  # Whether the agents answer this user's person now (config/agent_answerers.yml),
  # read without creating one: a user with no web identity and no linked person
  # is the public until their first message makes them one.
  def answered?
    identity = AgentPersonIdentity.find_by(platform: "web", external_id: current_user.id.to_s)
    person = identity&.person || AgentPerson.find_by(user_id: current_user.id)
    AgentMessages::Answerers.current.allowed?(person)
  end

  def load_app_and_cto
    @app = App.find_by(slug: params[:slug])
    raise ActiveRecord::RecordNotFound, "no such app" unless @app && AppOwnership.manage_app?(current_user, @app.slug)

    @cto = AppOwnership.cto_for_app(@app.slug)
    raise ActiveRecord::RecordNotFound, "no CTO" unless @cto
  end
end
