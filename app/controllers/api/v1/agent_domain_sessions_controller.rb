module Api
  module V1
    # The warm-session lease per domain (AgentDomainSession;
    # docs/agents/system/agent-message-loop.md, "Warm sessions"). bin/dispatcher
    # calls these from its main loop, never from a run thread.
    #
    #   GET  /api/v1/agent_domain_sessions                          the rows (no transcripts, no keys)
    #   POST /api/v1/agent_domain_sessions/:domain/acquire          { worker, lease_key? }  take or renew;
    #                                                                 409 LEASE_HELD; meta.lease_key once, on a take
    #   POST /api/v1/agent_domain_sessions/:domain/renew            { worker, lease_key }  the holder's heartbeat
    #   POST /api/v1/agent_domain_sessions/:domain/checkpoint       { worker, lease_key, session_id, turns,
    #                                                                 context_tokens, data }  data: base64 gzip
    #   POST /api/v1/agent_domain_sessions/:domain/checkpoint_read  { worker, lease_key }  the holder restores it
    #   POST /api/v1/agent_domain_sessions/:domain/release          { worker, lease_key }
    #   POST /api/v1/agent_domain_sessions/:domain/consolidate      { worker, lease_key, text, source_session_id?,
    #                                                                 turns_covered?, context_tokens? }
    #   POST /api/v1/agent_domain_sessions/:domain/fault            { worker, lease_key, fault, detail? }
    #
    # AUTH is the board's, narrowed: the shared token (the dispatcher's) or an
    # admin session. A soul's own session reaches none of this, because a
    # checkpoint is owner and team conversation text.
    #
    # THE SHARED TOKEN IS NOT ENOUGH. It sits in every agent shell, the worker
    # name is caller-asserted, and GET index shows the holder's. So every holder
    # verb also needs the LEASE KEY the board answered, once, to the acquire that
    # took the lease (AgentDomainSession, "The lease key"): only the process
    # holding the lease reads its domain's transcript or writes the session; a
    # wrong key reads as NOT_HOLDER. Not admin-session-only, because the standby
    # restoring a checkpoint is a dispatcher, which holds only the shared token.
    # The checkpoint read is a POST so the key rides in the (filtered) body,
    # never in a URL a router or proxy logs.
    class AgentDomainSessionsController < BaseController
      require_admin_session

      before_action :load_row, except: [ :index, :acquire ]

      def index
        render_data(AgentDomainSession.order(:domain).map { |row| row.as_api_json })
      end

      def acquire
        result = guarded do
          AgentDomainSession.acquire!(domain: params[:domain], worker: params[:worker], lease_key: lease_key)
        end
        return if performed?
        return render_refusal(result.refused) if result.refused

        render_data(result.row.as_api_json(for_holder: true),
                    meta: { taken_over_from: result.taken_over_from, lease_key: result.lease_key }.compact)
      end

      def renew
        guarded { @row.renew!(worker: worker, lease_key: lease_key) }
        return if performed?

        render_data(@row.reload.as_api_json(for_holder: true))
      end

      def checkpoint
        data = begin
          Base64.strict_decode64(params[:data].to_s)
        rescue ArgumentError
          return render_error("data must be base64", status: :unprocessable_entity, error_code: "BAD_CHECKPOINT")
        end
        guarded do
          @row.checkpoint!(worker: worker, lease_key: lease_key, session_id: params[:session_id], data: data,
                           turns: params[:turns], context_tokens: params[:context_tokens])
        end
        return if performed?

        render_data(@row.reload.as_api_json(for_holder: true))
      end

      def download
        bytes = guarded { @row.checkpoint_bytes_for(worker: worker, lease_key: lease_key) }
        return if performed?
        unless bytes
          return render_error("#{@row.domain} has no checkpoint", status: :not_found, error_code: "NO_CHECKPOINT")
        end

        render_data({ "domain" => @row.domain, "session_id" => @row.claude_session_id,
                      "checkpointed_at" => @row.checkpointed_at&.iso8601, "data" => Base64.strict_encode64(bytes) })
      end

      def release
        guarded { @row.release!(worker: worker, lease_key: lease_key) }
        return if performed?

        render_data(@row.reload.as_api_json)
      end

      def consolidate
        guarded do
          @row.consolidate!(worker: worker, lease_key: lease_key, text: params[:text],
                            source_session_id: params[:source_session_id], turns_covered: params[:turns_covered],
                            context_tokens: params[:context_tokens])
        end
        return if performed?

        render_data(@row.reload.as_api_json(for_holder: true))
      end

      def fault
        guarded { @row.fault!(worker: worker, lease_key: lease_key, fault: params[:fault], detail: params[:detail]) }
        return if performed?

        render_data(@row.reload.as_api_json)
      end

      private

      def worker = params[:worker].to_s.strip
      def lease_key = params[:lease_key].to_s

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
