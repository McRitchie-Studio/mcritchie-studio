module Api
  module V1
    # Login requests the operator grants (docs/agents/system/agent-sessions-design.md,
    # section 3): an admin login, or with `kind: harness_key` and a `label` naming
    # the machine, that machine's harness key.
    #
    #   POST /api/v1/agent_login_requests                post a request (steffon|xan)
    #   POST /api/v1/agent_login_requests/:slug/code     grant it with the one-time code
    #   POST /api/v1/agent_login_requests/:slug/collect  take the granted token, once
    #
    # All three are presented with the machine credential (the shared token, or a
    # harness key): a session cannot mint a session. `code` and `collect` also need the collect key `create` returned and
    # the harness session id it named; a `create` that would replace an open request
    # needs that request's collect key. No response carries the code.
    class AgentLoginRequestsController < BaseController
      STATUS = {
        forbidden: [ :forbidden, "LOGIN_FORBIDDEN" ],
        wrong_code: [ :forbidden, "WRONG_CODE" ],
        pending: [ :conflict, "LOGIN_PENDING" ],
        decided: [ :conflict, "LOGIN_DECIDED" ],
        lapsed: [ :gone, "LOGIN_LAPSED" ],
        refused: [ :gone, "LOGIN_REFUSED" ],
        collected: [ :gone, "LOGIN_COLLECTED" ],
        open: [ :conflict, "LOGIN_OPEN" ],
        too_many: [ :too_many_requests, "TOO_MANY_REQUESTS" ]
      }.freeze

      accepts_harness_key :create, :code, :collect
      before_action :refuse_a_session
      before_action :set_request, only: %i[code collect]

      rescue_from AgentLoginRequest::Refusal do |refusal|
        status, error_code = STATUS.fetch(refusal.kind)
        render_error(refusal.message, status: status, error_code: error_code)
      end

      def create
        if params[:harness_session_id].blank?
          return render_error("harness_session_id is required: the request belongs to one harness session",
                              status: :unprocessable_entity, error_code: "VALIDATION_FAILED")
        end

        login = AgentLoginRequest.request!(soul: params[:soul].to_s, harness_session_id: params[:harness_session_id],
                                           collect_key: params[:collect_key], kind: params[:kind], label: params[:label])
        render_data(login.summary.merge("collect_key" => login.collect_key), status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render_error(e.record.errors.full_messages.to_sentence, status: :unprocessable_entity,
                                                                error_code: "VALIDATION_FAILED")
      end

      def code
        session = @login.grant_with_code!(code: params[:code], collect_key: params[:collect_key],
                                          harness_session_id: params[:harness_session_id])
        render_data(@login.summary.merge("session" => session.summary))
      end

      def collect
        session = @login.collect!(collect_key: params[:collect_key], harness_session_id: params[:harness_session_id])
        render_data(session.summary.merge("token" => session.token))
      end

      private

      def refuse_a_session
        return unless current_agent_session

        render_session_refusal("a session cannot mint a session; present the machine credential")
      end

      def set_request
        @login = AgentLoginRequest.find_by(slug: params[:slug].to_s)
        render_error("login request not found", status: :not_found, error_code: "NOT_FOUND") unless @login
      end
    end
  end
end
