module Api
  module V1
    # bin/dispatcher's minute ping (docs/agents/agents/steffon/sops/agent-dispatcher.md).
    #
    #   POST /api/v1/agent_dispatchers/ping { worker, host, souls[], running, capacity,
    #                                         paused_until?, pause_reason?, state, version, started_at }
    #   GET  /api/v1/agent_dispatchers      the rows, newest ping first
    #
    # AUTH is the board's (BaseController): any agent session or the shared token.
    # A ping names no soul and writes only its own dispatcher row, so it carries no
    # soul scope; the floor alert reads the newest ping.
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
                                                                    pause_reason state version started_at]))
        rescue ArgumentError => e
          error = e
        end
        return render_error(error.message, status: :unprocessable_entity, error_code: "WORKER_REQUIRED") if error

        render_data(row.as_api_json)
      end
    end
  end
end
