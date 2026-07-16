require "test_helper"

# [integration] The Approve action path — POST /deployments/:run_id/approve. Admin-
# gated like every board mutation; on success it calls GitHub via the approver and
# clears the local gate (which re-broadcasts the panel); a failure logs to ErrorLog
# and leaves the gate up.
class GithubDeploymentsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @run = GithubWorkflowRun.create!(
      repo: "mcritchie/mcritchie-studio", run_id: 700_700, status: "in_progress",
      workflow_name: "Production Deploy", pending_environment: "production", pending_since: 1.hour.ago
    )
  end

  # A stub approver double whose #approve! records the call (or raises).
  def stub_approver(raising: nil)
    Object.new.tap do |obj|
      captured = @approver_calls = []
      obj.define_singleton_method(:approve!) do
        captured << true
        raise raising if raising

        { "state" => "approved" }
      end
    end
  end

  test "[integration] anonymous is redirected (not authorized) and the gate stays up" do
    post approve_deployment_path(@run.run_id)
    assert_response :redirect
    assert @run.reload.pending_approval?
  end

  test "[integration] a logged-in non-admin is bounced and the gate stays up" do
    log_in_as(@viewer)
    post approve_deployment_path(@run.run_id)
    assert_redirected_to root_path
    assert @run.reload.pending_approval?
  end

  test "[integration] an admin approve calls GitHub, clears the gate, and redirects" do
    log_in_as(@admin)
    approver = stub_approver
    passed_run = nil
    Github::DeploymentApprover.stub(:new, ->(run) { passed_run = run; approver }) do
      post approve_deployment_path(@run.run_id)
    end

    assert_equal @run.run_id, passed_run.run_id
    assert_equal 1, @approver_calls.size, "GitHub approve must be invoked exactly once"
    assert_not @run.reload.pending_approval?, "the local gate clears optimistically on success"
    assert_redirected_to deployments_path
  end

  test "[integration] an admin approve via turbo_stream re-renders the panel" do
    log_in_as(@admin)
    Github::DeploymentApprover.stub(:new, ->(_run) { stub_approver }) do
      post approve_deployment_path(@run.run_id), as: :turbo_stream
    end
    assert_response :success
    assert_match "github-actions-panel", @response.body
    assert_not @run.reload.pending_approval?
  end

  test "[integration] a GitHub failure logs to ErrorLog and leaves the gate up" do
    log_in_as(@admin)
    failing = stub_approver(raising: Github::DeploymentApprover::Error.new("boom"))
    assert_difference -> { ErrorLog.count }, 1 do
      Github::DeploymentApprover.stub(:new, ->(_run) { failing }) do
        post approve_deployment_path(@run.run_id)
      end
    end
    assert @run.reload.pending_approval?, "a failed approve must not clear the gate"
    assert_redirected_to deployments_path
  end

  test "[integration] approving a run that is not pending never calls GitHub" do
    @run.update!(pending_environment: nil, pending_since: nil)
    log_in_as(@admin)
    called = false
    Github::DeploymentApprover.stub(:new, ->(_run) { called = true; stub_approver }) do
      post approve_deployment_path(@run.run_id)
    end
    assert_not called
    assert_redirected_to deployments_path
  end

  test "[integration] approving an unknown run_id is handled gracefully" do
    log_in_as(@admin)
    post approve_deployment_path(999_999_999)
    assert_redirected_to deployments_path
  end
end
