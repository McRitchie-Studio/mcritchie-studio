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
      "Admin session granted to #{@login.soul} until #{session.expires_at.utc.iso8601}."
    end
  end

  # POST /agent_logins/:slug/refuse
  def refuse
    decide do
      @login.refuse!(by: current_user.email, reason: "declined by the operator")
      "Admin login for #{@login.soul} declined."
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
      format.html { redirect_to tasks_path, notice: notice, alert: alert }
    end
  end
end
