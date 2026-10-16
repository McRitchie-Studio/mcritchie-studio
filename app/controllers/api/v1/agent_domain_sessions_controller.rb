module Api
  module V1
    # The warm-session lease per domain (AgentDomainSession;
    # docs/agents/system/agent-message-loop.md, "Warm sessions"). bin/dispatcher
    # calls these from its main loop, never from a run thread.
    #
    #   GET  /api/v1/agent_domain_sessions                       the rows (no transcripts)
    #   POST /api/v1/agent_domain_sessions/:domain/acquire       { worker }  take or renew; 409 LEASE_HELD
    #   POST /api/v1/agent_domain_sessions/:domain/renew         { worker }  the holder's heartbeat
    #   POST /api/v1/agent_domain_sessions/:domain/checkpoint    { worker, session_id, turns, context_tokens,
    #                                                              data }   data: base64 of the gzipped transcript
    #   GET  /api/v1/agent_domain_sessions/:domain/checkpoint?worker=W      the holder restores it (base64)
    #   POST /api/v1/agent_domain_sessions/:domain/release       { worker }
    #   POST /api/v1/agent_domain_sessions/:domain/consolidate   { worker, text, source_session_id?,
    #                                                              turns_covered?, context_tokens? }
    #
    # Every write is holder-checked on the row (409 NOT_HOLDER / LEASE_LAPSED /
    # LEASE_HELD). AUTH is the board's, narrowed: the shared token (the
    # dispatcher's) or an admin session. A soul's own session reaches none of
    # this, because a checkpoint is owner and team conversation text.
    class AgentDomainSessionsController < BaseController
      require_admin_session

      before_action :load_row, except: [ :index, :acquire ]

      def index
        render_data(AgentDomainSession.order(:domain).map { |row| row.as_api_json })
      end

      def acquire
        result = guarded do
          AgentDomainSession.acquire!(domain: params[:domain], worker: params[:worker])
        end
        return if performed?
        return render_refusal(result.refused) if result.refused

        render_data(result.row.as_api_json(worker: worker),
                    meta: { taken_over_from: result.taken_over_from }.compact)
      end

      def renew
        guarded { @row.renew!(worker: worker) }
        return if performed?

        render_data(@row.reload.as_api_json(worker: worker))
      end

      def checkpoint
        data = begin
          Base64.strict_decode64(params[:data].to_s)
        rescue ArgumentError
          return render_error("data must be base64", status: :unprocessable_entity, error_code: "BAD_CHECKPOINT")
        end
        guarded do
          @row.checkpoint!(worker: worker, session_id: params[:session_id], data: data, turns: params[:turns],
                           context_tokens: params[:context_tokens])
        end
        return if performed?

        render_data(@row.reload.as_api_json(worker: worker))
      end

      def download
        bytes = guarded { @row.checkpoint_bytes_for(worker: worker) }
        return if performed?
        unless bytes
          return render_error("#{@row.domain} has no checkpoint", status: :not_found, error_code: "NO_CHECKPOINT")
        end

        render_data({ "domain" => @row.domain, "session_id" => @row.claude_session_id,
                      "checkpointed_at" => @row.checkpointed_at&.iso8601, "data" => Base64.strict_encode64(bytes) })
      end

      def release
        guarded { @row.release!(worker: worker) }
        return if performed?

        render_data(@row.reload.as_api_json)
      end

      def consolidate
        guarded do
          @row.consolidate!(worker: worker, text: params[:text], source_session_id: params[:source_session_id],
                            turns_covered: params[:turns_covered], context_tokens: params[:context_tokens])
        end
        return if performed?

        render_data(@row.reload.as_api_json(worker: worker))
      end

      private

      def worker = params[:worker].to_s.strip

      def load_row
        @row = AgentDomainSession.find_by!(domain: params[:domain].to_s)
      end

      # A write under rescue_and_log; the model's refusals are 409/422 answers,
      # not faults, and stay out of the error log.
      def guarded
        refusal = nil
        value = rescue_and_log(target: @row) do
          yield
        rescue AgentDomainSession::Refused => e
          refusal = e
          nil
        end
        render_refusal(refusal) if refusal
        value
      end

      CONFLICTS = %w[NOT_HOLDER LEASE_HELD LEASE_LAPSED].freeze

      def render_refusal(error)
        status = CONFLICTS.include?(error.code) ? :conflict : :unprocessable_entity
        render json: { error: error.message, error_code: error.code, meta: error.meta.presence }.compact, status: status
      end
    end
  end
end
