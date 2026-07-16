require "test_helper"

# [component] The GitHub Actions panel's pending-approval STATE, rendered on
# /deployments. A run blocked at a protected-environment gate shows the amber
# "awaiting approval" treatment; only an admin sees the Approve button.
class DeploymentsPanelTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @pending = GithubWorkflowRun.create!(
      repo: "mcritchie/mcritchie-studio", run_id: 424_242, status: "in_progress",
      workflow_name: "Production Deploy", head_sha: "9f2c1b7ad4e5c60f1e2d3a4b5c6d7e8f90123456",
      head_branch: "release", pending_environment: "production", pending_since: 3.hours.ago,
      html_url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/424242"
    )
  end

  test "[component] the panel renders the pending row with the awaiting-approval pill" do
    get deployments_path
    assert_response :success
    assert_select "[data-test='github-actions-panel']"
    assert_select "[data-test='github-actions-run'][data-state='pending_approval']" do
      assert_select "[data-test='github-actions-pill']", text: /awaiting approval/i
    end
    assert_select "[data-test='github-actions-waiting']", text: /waiting/i
  end

  test "[component] the pending row names the environment awaiting review" do
    get deployments_path
    assert_select "[data-state='pending_approval']", text: /production/
  end

  test "[component] the pending card renders an explicit link to the GitHub run page" do
    get deployments_path
    assert_select "[data-state='pending_approval'] a[data-test='github-actions-view-run']" do
      assert_select "[href=?]", @pending.html_url
      assert_select "[target='_blank']"
    end
    assert_select "[data-state='pending_approval'] a[data-test='github-actions-view-run']", text: /view run on github/i
  end

  test "[component] a normal run row is a whole-row anchor with a visible View-on-GitHub affordance" do
    passed = GithubWorkflowRun.create!(
      repo: "mcritchie/mcritchie-studio", run_id: 424_243, status: "completed", conclusion: "success",
      workflow_name: "CI", head_branch: "release",
      html_url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/424243"
    )
    get deployments_path
    assert_select "a[href=?][data-state='passed']", passed.html_url do
      assert_select "[data-test='github-actions-view-run']", text: /view on github/i
    end
  end

  test "[component] an admin sees the Approve button targeting the approve route" do
    log_in_as(@admin)
    get deployments_path
    assert_select "form[action=?][method=post]", approve_deployment_path(@pending.run_id)
    assert_select "button[data-test='github-actions-approve']", text: /approve/i
  end

  test "[component] a viewer sees the pending state but no Approve button" do
    log_in_as(@viewer)
    get deployments_path
    assert_select "[data-state='pending_approval']"
    assert_select "[data-test='github-actions-approve']", count: 0
    assert_select "[data-test='github-actions-approve-locked']"
  end

  test "[component] a non-pending run keeps the plain linked row (no approve control)" do
    @pending.update!(pending_environment: nil, pending_since: nil, status: "completed", conclusion: "success")
    log_in_as(@admin)
    get deployments_path
    assert_select "[data-test='github-actions-approve']", count: 0
    assert_select "[data-test='github-actions-run'][data-state='passed']"
  end
end
