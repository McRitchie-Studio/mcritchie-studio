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
# satellite's chat with Alex reaches for this person.
# Open to everyone (AdminWall::PUBLIC_ACTIONS). The session names a user with a proven
# email; anyone else is a random token in a signed, http-only cookie, as on a satellite's
# proxy (Studio::AgentChatsController), so no email or token is read from the
# browser. Sign-in folds a visitor's thread into the person's on the first poll.
# The caps are AgentChat::Caps, the same public budget as /build.
# The app on the row is "mcritchie-studio" (config/agent_routes.yml `web: apps:`).
#
# `voice` is what POST /voice/takes answered for a held take (epic
# .agents/epics/studio-voice.md, card 4): AgentChat::Voice keeps its check,
# score and length and names the speaker itself, so the dispatcher's prompt
# says who spoke (AgentContextBuilder#voice_line). No audio comes here.
class HubAgentChatsController < ApplicationController
  APP = "mcritchie-studio".freeze
  ANON_COOKIE = :studio_agent_chat_anon
  ANON_TTL = 1.year

  protect_from_forgery with: :exception
  before_action :no_store
  before_action :require_soul!
  # The poll reads the session and never writes it back. The session is a
  # cookie, so a poll that started before a session write (the first-name
  # ask's "Skip for now") would land after it and restore the old copy. The
  # home page's chat polls while that ask is open (task get-in-touch-side-by-side).
  before_action -> { request.session_options[:skip] = true }, only: :turns

  def create
    # Voice stays with admins, as POST /voice/takes does; anyone else's `voice` is dropped.
    voice = admin? ? AgentChat::Voice.from_param(params[:voice], user: current_user) : nil
    message = AgentChat::Ingest.new(app: APP, visitor: visitor(mint: true), ip: client_ip)
                               .call(params[:text], voice: voice, viewer: AgentChat::Viewer.for_user(current_user))
    cookies.delete(ANON_COOKIE) if verified_email && anon_token
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
    return render(json: { turns: [], pending: false }) unless verified_email || anon_token

    fold_on_sign_in
    thread_key = visitor.thread_key
    # `since` is a floor under `after`: the home page's chat starts fresh and
    # shows only turns newer than its render (LandingHelper#home_alex_chat).
    after = [ after_param, id_param(:since) ].compact.max
    rows = thread_key ? AgentChat.rows(thread_key, after: after, limit: limit_param) : []
    render json: { turns: AgentChat::Turns.for(rows), pending: AgentChat::Turns.pending?(thread_key) }
  rescue AgentChat::Visitor::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def soul = params[:soul].to_s.presence || Studio.agent_chat_soul_list.first.to_s

  def visitor(mint: false)
    return @visitor if @visitor

    @visitor = if (email = verified_email)
      AgentChat::Visitor.new(soul, email: email, anon_token: anon_token)
    else
      AgentChat::Visitor.new(soul, anon_token: anon_token || (mint_anon_token if mint))
    end
  end

  # The address a person's thread may be keyed on: only one they proved, as the
  # engine's proxy requires. /profile saves any address typed, so a claimed one
  # would open its owner's thread. Everyone else chats on the anon cookie.
  def verified_email
    current_user.email if current_user&.email.present? && current_user.email_verified_at.present?
  end

  # The first poll after sign-in brings the visitor's thread along, so it shows at
  # once and in order, not after the next message. The token is the signed cookie's.
  def fold_on_sign_in
    return unless verified_email && anon_token

    AgentChat::Ingest.new(app: APP, visitor: visitor).fold_visitor!
    cookies.delete(ANON_COOKIE)
    @visitor = nil
    @anon_cleared = true
  end

  def anon_token = @anon_cleared ? nil : cookies.signed[ANON_COOKIE].presence

  def mint_anon_token
    SecureRandom.urlsafe_base64(32).tap do |token|
      cookies.signed[ANON_COOKIE] = { value: token, expires: ANON_TTL.from_now, httponly: true, same_site: :lax, secure: request.ssl? }
    end
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

  def after_param = id_param(:after)

  def id_param(name)
    raw = params[name].to_s
    return nil if raw.empty?
    raise AgentChat::Visitor::Invalid, "#{name} must be a message id" unless raw.match?(/\A\d{1,18}\z/)

    raw.to_i
  end

  def limit_param
    raw = params[:limit].to_s
    return AgentChat::Turns::LIMIT if raw.empty?
    raise AgentChat::Visitor::Invalid, "limit must be a whole number" unless raw.match?(/\A\d{1,4}\z/)

    raw.to_i.clamp(1, AgentChat::Turns::LIMIT)
  end
end
