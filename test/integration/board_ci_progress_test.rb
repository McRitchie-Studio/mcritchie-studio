require "test_helper"

# [integration] The board's CI progress bars end to end: a submitted task card
# shows its PR's GitHub CI as "X / Y checks" plus a bar, and the Next Release card
# shows the same bar for the G3 candidate suite (the release-branch tip's CI). CI
# counts are injected through the CI_PROGRESS_FIXTURES seam so the render never
# touches the network.
class BoardCiProgressTest < ActionDispatch::IntegrationTest
  TASK_SHA = "task-head-sha".freeze
  RELEASE_SHA = "release-head-sha".freeze

  # A SHA the fixtures do NOT cover — so a bar for it can only come from ingested
  # CiCheckJob rows (the live path), never the fixture seam or the network.
  LIVE_SHA = "task-live-head-sha".freeze

  setup do
    GithubWorkflowRun.delete_all
    CiCheckJob.delete_all
    @prior_fixtures = ENV["CI_PROGRESS_FIXTURES"]
    ENV["CI_PROGRESS_FIXTURES"] = {
      TASK_SHA => { "passed" => 6, "failed" => 0, "pending" => 2 },
      RELEASE_SHA => { "passed" => 8, "failed" => 0, "pending" => 0 }
    }.to_json
  end

  teardown { ENV["CI_PROGRESS_FIXTURES"] = @prior_fixtures }

  test "[integration] a submitted task card shows its CI progress bar" do
    task = submitted_task(branch: "feat/ci-progress-demo", pr: 42)
    seed_run(branch: "feat/ci-progress-demo", sha: TASK_SHA)

    get deployments_path
    assert_response :success

    within = "#card-#{task.slug} [data-test='task-card-ci-progress']"
    assert_select within, 1
    assert_select "#{within} [data-test='task-ci-progress-fraction']", text: /6 \/ 8/
    assert_select "#{within} [role='progressbar'][aria-valuenow='6'][aria-valuemax='8']", 1
  end

  test "[integration] the Next Release card shows the G3 candidate CI bar" do
    Release.open! # the active candidate -> Release.current -> the Next Release card
    seed_run(branch: Release::BRANCH, sha: RELEASE_SHA)

    get deployments_path
    assert_response :success

    assert_select "#current-release [data-test='release-ci-progress']", 1
    assert_select "#current-release [data-test='release-ci-progress-fraction']", text: /8 \/ 8/
  end

  test "[integration] a submitted card renders its bar from LIVE workflow_job rows (no fixture, no API)" do
    task = submitted_task(branch: "feat/ci-live-demo", pr: 77)
    seed_run(branch: "feat/ci-live-demo", sha: LIVE_SHA)
    # 4 completed + 4 in_progress CI jobs — the ONLY source for this SHA's bar.
    seed_jobs(sha: LIVE_SHA, branch: "feat/ci-live-demo", passed: 4, pending: 4)

    get deployments_path
    assert_response :success

    within = "#card-#{task.slug} [data-test='task-card-ci-progress']"
    assert_select within, 1
    assert_select "#{within} [data-test='task-ci-progress-fraction']", text: /4 \/ 8/
    assert_select "#{within} [role='progressbar'][aria-valuenow='4'][aria-valuemax='8']", 1
    # The stable morph target wraps the bar, so a live push can swap it with no reload.
    assert_select "#ci-progress-#{task.slug}", 1
  end

  test "[integration] a task with no PR shows no CI bar" do
    task = Task.create!(title: "no pr yet", stage: "building",
                        metadata: { "devops" => { "branch" => "feat/no-pr", "repositories" => ["mcritchie-studio"] } })

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='task-card-ci-progress']", 0
  end

  private

  def submitted_task(branch:, pr:)
    Task.create!(
      title: "ci bar demo #{SecureRandom.hex(2)}",
      stage: "submitted",
      metadata: { "devops" => {
        "branch" => branch,
        "repositories" => ["mcritchie-studio"],
        "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/#{pr}"
      } }
    )
  end

  def seed_run(branch:, sha:)
    GithubWorkflowRun.create!(
      repo: "amcritchie/mcritchie-studio", workflow_name: "CI",
      run_id: SecureRandom.random_number(10**12), status: "in_progress",
      head_branch: branch, head_sha: sha, run_started_at: Time.current
    )
  end

  def seed_jobs(sha:, branch:, passed:, pending:)
    id = SecureRandom.random_number(10**12)
    passed.times  { CiCheckJob.create!(repo: "amcritchie/mcritchie-studio", job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: "CI", status: "completed", conclusion: "success") }
    pending.times { CiCheckJob.create!(repo: "amcritchie/mcritchie-studio", job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: "CI", status: "in_progress") }
  end
end
