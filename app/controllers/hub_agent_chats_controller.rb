require "ipaddr"

# The engine agent chat's two calls (studio-engine docs/AGENT_CHAT.md), answered
# IN-PROCESS on the hub, which holds every thread. On a satellite the engine's
# Studio::AgentChatsController proxies them to the hub over HTTP; on the hub that
# would be the hub calling itself, so these routes are drawn BEFORE
# Studio.routes and win recognition for the same paths:
#
#   POST /agent_chat/messages   soul, text, voice (optional)   201 {turn, voice} · 422 · 429 · 404
#   GET  /agent_chat/turns      soul, after, limit             200 {turns, pending}
#
# The page is /chat (ChatController#index), the hub's own chat with Alex on the
# engine primitive: thread chat:<soul>:<user id> (AgentChat), the same thread a
# satellite's chat with Alex reaches for this person. SIGNED IN ONLY: the
# session names the user, so no email or anon token is read from the browser.
# The app on the row is "mcritchie-studio" (config/agent_routes.yml `web: apps:`).
#
# `voice` is what POST /voice/takes answered for a held take (epic
# .agents/epics/studio-voice.md, card 4): AgentChat::Voice keeps its check,
# score and length and names the speaker itself, so the dispatcher's prompt
# says who spoke (AgentContextBuilder#voice_line). No audio comes here.
class HubAgentChatsController < ApplicationController
  APP = "mcritchie-studio".freeze

  before_action :require_authentication
  protect_from_forgery with: :exception
  before_action :no_store
  before_action :require_soul!

  def create
    voice = AgentChat::Voice.from_param(params[:voice], user: current_user)
    message = AgentChat::Ingest.new(app: APP, visitor: visitor, ip: client_ip).call(params[:text], voice: voice)
    # `voice` is what the row keeps (and the dispatcher's prompt reads), so the
    # page says who Alex was told spoke, not what the browser sent.
    render json: { turn: AgentChat::Turns.for_row(message).first, voice: message.envelope["voice"] }.compact, status: :created
  rescue AgentChat::Ingest::Capped => e
    render json: { error: e.message }, status: :too_many_requests
  rescue AgentChat::Ingest::Refused, AgentChat::Voice::Invalid, AgentChat::Visitor::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue AgentChat::Ingest::NotAvailable
    no_web_chat
  end

  def turns
    thread_key = visitor.thread_key
    rows = thread_key ? AgentChat.rows(thread_key, after: after_param, limit: limit_param) : []
    render json: { turns: AgentChat::Turns.for(rows), pending: AgentChat::Turns.pending?(thread_key) }
  rescue AgentChat::Visitor::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def soul = params[:soul].to_s.presence || Studio.agent_chat_soul_list.first.to_s

  def visitor
    @visitor ||= AgentChat::Visitor.new(soul, email: current_user.email)
  end

  # Only a soul this app names (Studio.agent_chat_souls) AND config/agent_routes.yml
  # lets the hub's own chat address, as a satellite's proxy and the hub API check.
  def require_soul!
    no_web_chat unless Studio.agent_chat_soul_list.include?(soul) && AgentChat.available?(APP, soul)
  end

  def no_web_chat
    render json: { error: "#{soul[0, 40].presence || 'That agent'} has no web chat here" }, status: :not_found
  end

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end

  def client_ip
    IPAddr.new(request.remote_ip.to_s).to_s
  rescue IPAddr::Error
    nil
  end

  def after_param
    raw = params[:after].to_s
    return nil if raw.empty?
    raise AgentChat::Visitor::Invalid, "after must be a message id" unless raw.match?(/\A\d{1,18}\z/)

    raw.to_i
  end

  def limit_param
    raw = params[:limit].to_s
    return AgentChat::Turns::LIMIT if raw.empty?
    raise AgentChat::Visitor::Invalid, "limit must be a whole number" unless raw.match?(/\A\d{1,4}\z/)

    raw.to_i.clamp(1, AgentChat::Turns::LIMIT)
  end
end
