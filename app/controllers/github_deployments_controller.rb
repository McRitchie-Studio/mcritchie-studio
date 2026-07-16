# Board action for the operator-approval gate on prod deploys (v1.1 of the GitHub
# Actions panel). ADMIN-GATED like every board mutation — a viewer can SEE a
# pending deploy on /deployments, but only an admin can approve it.
#
# #approve reads the run's pending environment(s) and approves them via GitHub,
# then optimistically clears the local pending flag. Clearing the flag fires
# GithubWorkflowRun's after_commit → DeploymentsBroadcaster.github_actions, so
# every open /deployments viewer sees the row leave "awaiting approval" live —
# and GitHub's follow-up deployment_review/workflow_run webhooks reconcile it.
class GithubDeploymentsController < ApplicationController
  before_action :require_admin

  def approve
    run = GithubWorkflowRun.find_by(run_id: params[:run_id])
    return respond_not_pending unless run&.pending_approval?

    rescue_and_log(target: nil) do
      Github::DeploymentApprover.new(run).approve!
      # Optimistic: the approve succeeded, so drop the gate now (the webhook will
      # confirm). The update's after_commit re-broadcasts the panel to all viewers.
      run.update!(pending_environment: nil, pending_since: nil)
    end

    respond_approved
  rescue StandardError
    # rescue_and_log already captured the exception to ErrorLog and re-raised.
    respond_failed
  end

  private

  def respond_approved
    respond_to do |format|
      format.turbo_stream { render turbo_stream: panel_stream }
      format.html { redirect_to deployments_path, notice: "Deploy approved" }
    end
  end

  def respond_not_pending
    respond_to do |format|
      format.turbo_stream { render turbo_stream: panel_stream, status: :ok }
      format.html { redirect_to deployments_path, alert: "That deploy is not awaiting approval" }
    end
  end

  def respond_failed
    respond_to do |format|
      format.turbo_stream { render turbo_stream: panel_stream, status: :unprocessable_entity }
      format.html { redirect_to deployments_path, alert: "Could not approve the deploy — check the error log" }
    end
  end

  # Re-render the whole Actions panel from fresh state so the caller's DOM matches
  # the broadcast every other viewer receives.
  def panel_stream
    turbo_stream.replace(
      "github-actions-panel",
      partial: "tasks/github_actions_panel",
      locals: { runs: GithubWorkflowRun.latest_per_workflow }
    )
  end
end
