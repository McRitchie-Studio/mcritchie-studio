module Api
  module V1
    # bin/client-build-launcher's change-card calls (ChangeBuilds; runbook:
    # docs/agents/system/client-build-launcher.md, "Change cards").
    #
    #   GET  /api/v1/change_builds                  designed change cards it may start, oldest first
    #   POST /api/v1/change_builds/:slug/claim      { worker, run }               records the start
    #   POST /api/v1/change_builds/:slug/finish     { run, outcome, reason?, desk? }  started | refused
    #   GET  /api/v1/change_builds/builders         started owner-go cards whose builder may run now
    #   POST /api/v1/change_builds/:slug/builder_claim   { worker, run }      records a builder run; the brief's fields
    #   POST /api/v1/change_builds/:slug/builder_finish  { run, outcome, reason?, log? }  finished | failed | released
    #
    # AUTH: an admin session or the shared token, as Api::V1::ClientBuildsController.
    # A refusal answers 409 (404 for an unknown task, 400 for a bad call) with
    # error_code naming it, and changes nothing.
    class ChangeBuildsController < BaseController
      require_admin_session

      REFUSAL_STATUS = { not_found: :not_found, bad_request: :bad_request }.freeze

      def index
        render_data(ChangeBuilds.candidates, meta: { max_attempts: ChangeBuilds.max_attempts })
      end

      def builders
        render_data(ChangeBuilds.builder_candidates, meta: { max_attempts: ChangeBuilds.builder_max_attempts,
                                                             enabled: ChangeBuilds.builder_enabled? })
      end

      def builder_claim
        refusing { render_data(ChangeBuilds.builder_claim!(params[:slug], worker: params[:worker], run: params[:run])) }
      end

      def builder_finish
        refusing do
          task = ChangeBuilds.builder_finish!(params[:slug], run: params[:run].to_s, outcome: params[:outcome].to_s,
                                                             reason: params[:reason], log: params[:log])
          render_data({ "slug" => task.slug, "stage" => task.stage, "builder" => ChangeBuilds.builder_of(task) })
        end
      end

      def claim
        refusing { render_data(ChangeBuilds.claim!(params[:slug], worker: params[:worker], run: params[:run])) }
      end

      def finish
        refusing do
          task = ChangeBuilds.finish!(params[:slug], run: params[:run].to_s, outcome: params[:outcome].to_s,
                                                     reason: params[:reason], desk: params[:desk])
          render_data({ "slug" => task.slug, "stage" => task.stage, "change_build" => ChangeBuilds.run_of(task) })
        end
      end

      private

      def refusing
        rescue_and_log do
          yield
        rescue ChangeBuilds::Refused => e
          render_error(e.message, status: REFUSAL_STATUS.fetch(e.code, :conflict), error_code: e.code.to_s.upcase)
        end
      rescue StandardError => e
        render_exception(e)
      end
    end
  end
end
