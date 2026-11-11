# The operator's answer to an admin login request, from the board
# (docs/agents/system/agent-sessions-design.md, section 3). AdminWall lists neither
# action, so only an admin reaches them. No response carries a token: the
# requesting harness collects it from the API.
class AgentLoginRequestsController < ApplicationController
  before_action :set_request

  # POST /agent_logins/:slug/approve
  def approve
    decide do
      session = @login.approve!(by: current_user.email)
      if @login.harness_key?
        "Harness key #{session.slug} granted to #{@login.label}."
      else
        "Admin session granted to #{@login.soul} until #{session.expires_at.utc.iso8601}."
      end
    end
  end

  # POST /agent_logins/:slug/refuse
  def refuse
    decide do
      @login.refuse!(by: current_user.email, reason: "declined by the operator")
      @login.harness_key? ? "Harness key for #{@login.label} declined." : "Admin login for #{@login.soul} declined."
    end
  end

  private

  def set_request
    @login = AgentLoginRequest.find_by(slug: params[:slug].to_s)
    answer({ error: "admin login request not found" }, :not_found, alert: "Admin login request not found") unless @login
  end

  # Runs one decision and answers with the notice it returns. A request that can
  # no longer be decided answers 409 with the reason.
  def decide
    rescue_and_log(target: @login) do
      notice = yield
      answer({ data: @login.summary }, :ok, notice: notice)
    rescue AgentLoginRequest::Refusal => e
      answer({ error: e.message }, :conflict, alert: e.message)
    end
  end

  def answer(body, status, notice: nil, alert: nil)
    respond_to do |format|
      format.json { render json: body, status: status }
      # The board's taps are plain forms (agent_login_requests/_pending): land back
      # on the board they were tapped from, with the outcome as the flash. 303, so
      # Turbo follows the POST's redirect as a GET visit.
      format.html { redirect_back_or_to deployments_path, notice: notice, alert: alert, status: :see_other }
    end
  end
end
