module Api
  module V1
    # The agent mailbox over the board API (docs/agents/system/agent-message-loop.md):
    # what `bin/dispatcher` and `bin/heartbeat` claim, renew and complete, and what
    # `bin/agent-inbox` reads.
    #
    #   GET  /api/v1/agent_messages            list (soul, status, channel, since, limit)
    #   GET  /api/v1/agent_messages/next       the message a claim would take now; writes nothing
    #   GET  /api/v1/agent_messages/:id        one message with its event timeline
    #   POST /api/v1/agent_messages/claim      { soul | souls[], worker, channel?, wait? } -> the claimed message or null
    #   POST /api/v1/agent_messages/:id/complete { worker, response_text, action_summary? }
    #   POST /api/v1/agent_messages/:id/release  { worker, reason?, code? }   code usage_limit refunds the attempt
    #   POST /api/v1/agent_messages/:id/renew    { worker }                   the holder extends its lease
    #
    # LONG POLL. A claim with `wait` (seconds, capped at WAIT_CAP) holds the
    # request until a claimable message exists, retrying the claim every
    # POLL_INTERVAL, and answers data null at the deadline. THREAD COST: the
    # request occupies one puma thread for up to WAIT_CAP. Production runs
    # WEB_CONCURRENCY 2 x RAILS_MAX_THREADS 3 = 6 threads, and one bin/dispatcher
    # holds one of them nearly always, so a second dispatcher is the most this
    # should carry. Each tick is one short claim transaction; nothing is held
    # between ticks but the request thread. WAIT_CAP stays well under Heroku's
    # 30-second router timeout.
    #
    # AUTH is the board's, unchanged (BaseController): an agent session or the
    # shared secret's token. A SESSION acts only for its own soul: an admin session
    # (Steffon, Xan) may act for any soul, any other session only for the soul it
    # names. A client session and a harness key reach none of this. The shared
    # token carries no soul, so the `soul` it sends is the actor, exactly as every
    # other board write records it (session_actor).
    class AgentMessagesController < BaseController
      before_action :load_message, only: [ :show, :complete, :release, :renew ]
      before_action :require_soul_scope!, only: [ :next_message, :claim, :complete, :release, :renew ]

      LIST_LIMIT = 200
      WAIT_CAP = 20
      POLL_INTERVAL = 1
      # Tests replace this to make arrival and timeout deterministic.
      class_attribute :long_poll_sleeper, default: ->(seconds) { sleep(seconds) }

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
        wait = params[:wait].to_f.clamp(0, WAIT_CAP)
        deadline = Time.current + wait
        result = nil
        loop do
          result = guarded do
            AgentMessage.claim!(soul: acting_souls, worker: params[:worker], channel: params[:channel].presence,
                                actor: claim_actor)
          end
          return if performed?
          break if result.message || Time.current >= deadline

          long_poll_sleeper.call([ POLL_INTERVAL, deadline - Time.current ].min)
        end

        render_data(result.message&.as_api_json, meta: { reason: result.reason, waited: wait.positive? })
      end

      def renew
        guarded(target: @message) do
          @message.renew!(worker: params[:worker], actor: session_actor(acting_soul))
        end
        return if performed?

        render_data(@message.reload.as_api_json)
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
          @message.release!(worker: params[:worker], reason: params[:reason], code: params[:code],
                            actor: session_actor(acting_soul))
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

      # Every soul this call acts for: the message's own on a member route, else
      # `souls` (an array, or one comma-separated string) plus `soul`.
      def acting_souls
        return [ acting_soul ].reject(&:empty?) if @message

        listed = params[:souls].is_a?(Array) ? params[:souls] : params[:souls].to_s.split(",")
        (listed.map { |s| s.to_s.strip } + [ params[:soul].to_s.strip ]).reject(&:empty?).uniq
      end

      # A single-soul claim keeps its actor as before; a multi-soul claim records
      # each message's own soul (AgentMessage.claim!) unless a session names one.
      def claim_actor
        souls = acting_souls
        souls.one? ? session_actor(souls.first) : current_agent_session&.soul
      end

      def require_soul_scope!
        souls = acting_souls
        if souls.empty?
          return render_error("soul is required", status: :unprocessable_entity, error_code: "SOUL_REQUIRED")
        end

        session = current_agent_session
        return if session.nil? || session.admin?

        foreign = souls.reject { |soul| Task.canonical_soul(session.soul) == Task.canonical_soul(soul) }
        return if foreign.empty?

        render_session_refusal("#{session.soul}'s #{session.tier} session cannot act for #{foreign.join(', ')}; " \
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
