module Api
  module V1
    # The agent mailbox over the board API (docs/agents/system/agent-message-loop.md):
    # what `bin/heartbeat` claims and completes, and what `bin/agent-inbox` reads.
    #
    #   GET  /api/v1/agent_messages            list (soul, status, channel, since, limit)
    #   GET  /api/v1/agent_messages/next       the message a claim would take now; writes nothing
    #   GET  /api/v1/agent_messages/:id        one message with its event timeline
    #   POST /api/v1/agent_messages/claim      { soul, worker, channel? } -> the claimed message or null
    #   POST /api/v1/agent_messages/:id/complete { worker, response_text, action_summary? }
    #   POST /api/v1/agent_messages/:id/release  { worker, reason? }
    #
    # AUTH is the board's, unchanged (BaseController): an agent session or the
    # shared secret's token. A SESSION acts only for its own soul: an admin session
    # (Steffon, Xan) may act for any soul, any other session only for the soul it
    # names. A client session and a harness key reach none of this. The shared
    # token carries no soul, so the `soul` it sends is the actor, exactly as every
    # other board write records it (session_actor).
    class AgentMessagesController < BaseController
      before_action :load_message, only: [ :show, :complete, :release ]
      before_action :require_soul_scope!, only: [ :next_message, :claim, :complete, :release ]

      LIST_LIMIT = 200

      def index
        scope = AgentMessage.newest_first
        scope = scope.for_soul(params[:soul]) if params[:soul].present?
        scope = scope.with_status(params[:status]) if params[:status].present?
        scope = scope.on_channel(params[:channel]) if params[:channel].present?
        scope = scope.where("updated_at > ?", Time.zone.parse(params[:since])) if params[:since].present?
        limit = params[:limit].to_i.clamp(1, LIST_LIMIT) if params[:limit].present?
        render_data(scope.limit(limit || 50).map(&:as_api_json))
      end

      def show
        render_data(@message.as_api_json(events: true))
      end

      def next_message
        message = AgentMessage.claimable(soul: acting_soul, channel: params[:channel].presence).first
        render_data(message&.as_api_json)
      end

      # Always 200: an empty claim (data null, reason nothing_waiting) is the
      # normal idle answer, so a polling worker never mistakes it for an error.
      def claim
        result = guarded do
          AgentMessage.claim!(soul: acting_soul, worker: params[:worker], channel: params[:channel].presence,
                              actor: session_actor(acting_soul))
        end
        return if performed?

        render_data(result.message&.as_api_json, meta: { reason: result.reason })
      end

      def complete
        outcome = guarded(target: @message) do
          @message.complete!(worker: params[:worker], response_text: params[:response_text],
                             action_summary: params[:action_summary], actor: session_actor(acting_soul))
        end
        return if performed?

        render_data(@message.reload.as_api_json, meta: { outcome: outcome.to_s })
      end

      def release
        guarded(target: @message) do
          @message.release!(worker: params[:worker], reason: params[:reason], actor: session_actor(acting_soul))
        end
        return if performed?

        render_data(@message.reload.as_api_json)
      end

      private

      def load_message
        @message = AgentMessage.find(params[:id])
      end

      # The soul this call acts for: the message's own on a member route, else the
      # `soul` param.
      def acting_soul
        @message ? @message.soul_slug.to_s : params[:soul].to_s.strip
      end

      def require_soul_scope!
        if acting_soul.empty?
          return render_error("soul is required", status: :unprocessable_entity, error_code: "SOUL_REQUIRED")
        end

        session = current_agent_session
        return if session.nil? || session.admin? || Task.canonical_soul(session.soul) == Task.canonical_soul(acting_soul)

        render_session_refusal("#{session.soul}'s #{session.tier} session cannot act for #{acting_soul}; " \
                               "a session acts only for its own soul (an admin session for any)")
      end

      # A write under rescue_and_log, with the model's REFUSALS (not the holder,
      # nothing to say) answered as 409/422 and kept out of the error log: a
      # refusal is the guard working, not a fault. rescue_and_log re-raises
      # anything else for the base controller to answer.
      def guarded(target: nil)
        refusal = nil
        value = rescue_and_log(target: target) do
          yield
        rescue AgentMessage::Refused => e
          refusal = e
          nil
        end
        render_refusal(refusal) if refusal
        value
      end

      def render_refusal(error)
        status = error.code == "NOT_HOLDER" ? :conflict : :unprocessable_entity
        render_error(error.message, status: status, error_code: error.code)
      end
    end
  end
end
