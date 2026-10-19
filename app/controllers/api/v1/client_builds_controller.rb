module Api
  module V1
    # bin/client-build-launcher's board calls (ClientBuilds; runbook:
    # docs/agents/system/client-build-launcher.md).
    #
    #   GET  /api/v1/client_builds[?worker=]          designed launch tasks, oldest first,
    #                                                 and meta.in_flight (the worker's runs)
    #   POST /api/v1/client_builds/:slug/claim        { worker, run }  designed -> building + intake
    #   POST /api/v1/client_builds/:slug/progress     { run, kind }    a CTO chat line
    #   POST /api/v1/client_builds/:slug/finish       { run, outcome, reason?, version? }
    #
    # AUTH: an admin session or the shared token (the launcher's, like the
    # dispatcher's). A studio session scoped to one task cannot drive another app's
    # build. A refusal answers 409 (404 for an unknown task, 400 for a bad call)
    # with error_code naming it, and changes nothing.
    class ClientBuildsController < BaseController
      require_admin_session

      REFUSAL_STATUS = { not_found: :not_found, bad_request: :bad_request }.freeze

      def index
        render_data(ClientBuilds.candidates,
                    meta: { in_flight: ClientBuilds.in_flight(worker: params[:worker].presence),
                            max_attempts: ClientBuilds.max_attempts, preview_domain: ClientBuilds.preview_domain })
      end

      def claim
        refusing { render_data(ClientBuilds.claim!(params[:slug], worker: params[:worker], run: params[:run])) }
      end

      def progress
        refusing do
          message = ClientBuilds.progress!(params[:slug], kind: params[:kind].to_s, run: params[:run].to_s)
          render_data({ "message_id" => message.id, "kind" => params[:kind].to_s })
        end
      end

      def finish
        refusing do
          task = ClientBuilds.finish!(params[:slug], run: params[:run].to_s, outcome: params[:outcome].to_s,
                                                     reason: params[:reason], version: params[:version])
          render_data({ "slug" => task.slug, "stage" => task.stage, "blocked" => task.blocked?,
                        "client_build" => ClientBuilds.run_of(task) })
        end
      end

      private

      def refusing
        rescue_and_log do
          yield
        rescue ClientBuilds::Refused => e
          render_error(e.message, status: REFUSAL_STATUS.fetch(e.code, :conflict), error_code: e.code.to_s.upcase)
        end
      rescue StandardError => e
        render_exception(e)
      end
    end
  end
end
