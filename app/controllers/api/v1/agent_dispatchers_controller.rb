module Api
  module V1
    # bin/dispatcher's minute ping (docs/agents/agents/steffon/sops/agent-dispatcher.md).
    #
    #   POST /api/v1/agent_dispatchers/ping { worker, host, souls[], running, capacity,
    #                                         paused_until?, pause_reason?, state, version, started_at,
    #                                         op_ok?, gh_ok?, power?, harness_measured_at? }
    #
    # op_ok / gh_ok / power are the Mac's harness health, measured on each beat
    # (AgentMailbox::HarnessProbe) and stored on the row (AgentDispatcher.record_harness).
    #   GET  /api/v1/agent_dispatchers      the rows, newest ping first
    #
    # AUTH is the board's (BaseController): any agent session or the shared token.
    # A ping names no soul and writes only its own dispatcher row, so it carries no
    # soul scope; the floor alert reads the newest primary ping. The answer carries
    # the row's role and meta.primary_live, which a standby dispatcher reads.
    class AgentDispatchersController < BaseController
      LIST_LIMIT = 20

      def index
        render_data(AgentDispatcher.newest_first.limit(LIST_LIMIT).map(&:as_api_json),
                    meta: { silent: AgentDispatcher.silent? })
      end

      def ping
        row = nil
        error = nil
        rescue_and_log do
          row = AgentDispatcher.ping!(params.to_unsafe_h.slice(*%w[worker host souls running capacity paused_until
                                                                    pause_reason state version started_at
                                                                    op_ok gh_ok power harness_measured_at]))
        rescue ArgumentError => e
          error = e
        end
        return render_error(error.message, status: :unprocessable_entity, error_code: "WORKER_REQUIRED") if error

        # The role is the board's (AgentDispatcher.set_role!): the dispatcher reads
        # it, and whether a primary is live, from this answer every minute.
        render_data(row.as_api_json, meta: { primary_live: AgentDispatcher.primary_live? })
      end
    end
  end
end
