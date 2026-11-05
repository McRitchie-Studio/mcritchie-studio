require "ipaddr"

module Api
  module V1
    # The hub side of the shared agent chat (epic .agents/epics/agent-chat-primitive.md,
    # "Contract"; docs/agents/system/agent-message-loop.md, "Satellite chat"). A
    # satellite's SERVER calls these; the browser only ever talks to its own app.
    #
    #   POST /api/v1/agent_chat/messages  soul, text, person, ip, voice (optional)
    #        201 {turn, voice} · 422 {error} · 429 {error} capped · 404 soul has no web chat
    #   GET  /api/v1/agent_chat/turns     soul, person, after, limit (≤ 50)
    #        200 {turns: [...], pending: bool}
    #
    # A turn's status is pending, typing, answered, held or failed
    # (AgentChat::Turns). A 429 stores nothing; its count includes held rows
    # (AgentChat::Caps).
    #
    # AUTH is the calling APP's own bearer credential (AppCredential, purpose
    # agent-chat; 1Password `agent-chat.<slug>.applications`, the app's AGENT_CHAT_TOKEN),
    # never an agent session or a user token: 401 without a live one. The app
    # may address only the souls config/agent_routes.yml `web: apps:` lists for
    # it (else 404, the same answer as a soul with no web chat). `person` is
    # `{email}` when the app's visitor is signed in, else `{anon_token}`; the hub
    # decides the person and the thread (AgentChat::Visitor).
    #
    # `voice` is what the app's own POST /voice/takes answered for a spoken
    # message ({score, check, duration_ms}; the words are `text`, and no audio
    # ever comes here). AgentChat::Voice keeps the check, score and length and
    # names the speaker from `person` alone: a name in the payload is ignored,
    # so the dispatcher's prompt can only say what the hub decided
    # (AgentContextBuilder#voice_line). 201 repeats the voice the row kept, so
    # the page shows who the agent was told spoke.
    class AgentChatsController < BaseController
      skip_before_action :authenticate_api!
      before_action :authenticate_app!
      before_action :require_soul!

      def create
        visitor = AgentChat::Visitor.from_param(params[:soul], params[:person])
        voice = AgentChat::Voice.from_visitor(params[:voice], visitor)
        message = AgentChat::Ingest.new(app: @credential.app_slug, visitor: visitor, ip: client_ip).call(params[:text], voice: voice, viewer: params[:viewer])
        render json: { turn: AgentChat::Turns.for_row(message).first, voice: message.envelope["voice"] }.compact, status: :created
      rescue AgentChat::Ingest::Capped => e
        render_error(e.message, status: :too_many_requests, error_code: "CAPPED")
      end

      def turns
        visitor = AgentChat::Visitor.from_param(params[:soul], params[:person])
        thread_key = visitor.thread_key
        rows = thread_key ? AgentChat.rows(thread_key, after: after_param, limit: limit_param) : []
        render json: { turns: AgentChat::Turns.for(rows), pending: AgentChat::Turns.pending?(thread_key) }
      end

      rescue_from AgentChat::Visitor::Invalid do |e|
        render_error(e.message, status: :unprocessable_entity, error_code: "INVALID")
      end
      rescue_from AgentChat::Voice::Invalid do |e|
        render_error(e.message, status: :unprocessable_entity, error_code: "INVALID_VOICE")
      end
      rescue_from AgentChat::Ingest::Refused do |e|
        render_error(e.message, status: :unprocessable_entity, error_code: e.code)
      end
      rescue_from AgentChat::Ingest::NotAvailable do
        no_web_chat
      end

      private

      def authenticate_app!
        token = request.headers["Authorization"].to_s[/\ABearer\s+(\S+)\z/, 1]
        @credential = AppCredential.authenticate(token, purpose: "agent-chat")
        return if @credential

        render_error("An app's agent-chat credential is required", status: :unauthorized, error_code: "UNAUTHORIZED")
      end

      def require_soul!
        no_web_chat unless AgentChat.available?(@credential.app_slug, params[:soul].to_s)
      end

      def no_web_chat
        render_error("#{params[:soul].to_s[0, 40].presence || 'That agent'} has no web chat for this app",
                     status: :not_found, error_code: "NO_WEB_CHAT")
      end

      # The visitor's IP the app forwards, for the per-IP cap (hashed; never stored).
      def client_ip
        raw = params[:ip].to_s.strip
        return nil if raw.empty?

        IPAddr.new(raw).to_s
      rescue IPAddr::Error
        raise AgentChat::Visitor::Invalid, "ip is not an IP address"
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
  end
end
