require "test_helper"

# [integration] The board's CI progress meters end to end: a submitted task card
# shows its PR's GitHub CI — as one glyph per check for a small suite (v1.2), or the
# numeric "X / Y" + bar for a large one — and the whole meter links to the PR in a
# new tab. The Next Release card shows the same for the G3 candidate suite. Counts
# are injected through the CI_PROGRESS_FIXTURES seam so the render never touches the
# network; the live re-run case folds ingested CiCheckJob rows directly.
class BoardCiProgressTest < ActionDispatch::IntegrationTest
  TASK_SHA = "task-head-sha".freeze        # 8 checks -> symbolic
  RELEASE_SHA = "release-head-sha".freeze  # 8 checks -> symbolic
  MANY_SHA = "task-many-sha".freeze        # 14 checks -> numeric bar

  # A SHA the fixtures do NOT cover — so a meter for it can only come from ingested
  # CiCheckJob rows (the live path), never the fixture seam or the network.
  LIVE_SHA = "task-live-head-sha".freeze
  RERUN_SHA = "task-rerun-head-sha".freeze

  setup do
    GithubWorkflowRun.delete_all
    CiCheckJob.delete_all
    @prior_fixtures = ENV["CI_PROGRESS_FIXTURES"]
    ENV["CI_PROGRESS_FIXTURES"] = {
      TASK_SHA => { "passed" => 6, "failed" => 0, "pending" => 2 },
      RELEASE_SHA => { "passed" => 8, "failed" => 0, "pending" => 0 },
      MANY_SHA => { "passed" => 9, "failed" => 0, "pending" => 5 }
    }.to_json
  end

  teardown { ENV["CI_PROGRESS_FIXTURES"] = @prior_fixtures }

  test "[integration] a small suite shows one symbol per check, linked to the PR" do
    task = submitted_task(branch: "feat/ci-progress-demo", pr: 42)
    seed_run(branch: "feat/ci-progress-demo", sha: TASK_SHA)

    get deployments_path
    assert_response :success

    within = "#card-#{task.slug} [data-test='task-card-ci-progress']"
    assert_select within, 1
    assert_select "#card-#{task.slug} [data-test='task-ci-progress-symbols']", 1
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol']", 8, "one glyph per check"
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol'][data-ci-check-state='pending']", 2
    assert_select "#card-#{task.slug} [data-test='task-ci-progress-fraction']", 0, "symbols replace the fraction"

    # The whole meter is a link to the PR, opening in a new tab.
    assert_select "#card-#{task.slug} a[data-test='task-card-ci-progress']" \
                  "[href='https://github.com/amcritchie/mcritchie-studio/pull/42'][target='_blank'][rel='noopener']", 1
  end

  test "[integration] a large suite keeps the numeric X / Y bar" do
    task = submitted_task(branch: "feat/ci-many-demo", pr: 43)
    seed_run(branch: "feat/ci-many-demo", sha: MANY_SHA)

    get deployments_path
    assert_response :success

    within = "#card-#{task.slug} [data-test='task-card-ci-progress']"
    assert_select "#{within} [data-test='task-ci-progress-fraction']", text: /9 \/ 14/
    assert_select "#{within} [role='progressbar'][aria-valuenow='9'][aria-valuemax='14']", 1
    assert_select "#card-#{task.slug} [data-test='task-ci-progress-symbols']", 0, "12+ checks stay numeric"
  end

  test "[integration] the Next Release card shows the G3 candidate CI meter" do
    Release.open! # the active candidate -> Release.current -> the Next Release card
    seed_run(branch: Release::BRANCH, sha: RELEASE_SHA)

    get deployments_path
    assert_response :success

    assert_select "#current-release [data-test='release-ci-progress-symbols'][data-ci-state='green']", 1
    assert_select "#current-release [data-test='ci-check-symbol']", 8
    assert_select "#current-release a", 0, "the release meter has no single PR to link"
  end

  test "[integration] a submitted card renders its meter from LIVE workflow_job rows (no fixture, no API)" do
    task = submitted_task(branch: "feat/ci-live-demo", pr: 77)
    seed_run(branch: "feat/ci-live-demo", sha: LIVE_SHA)
    # 4 completed + 4 in_progress CI jobs — the ONLY source for this SHA's meter.
    seed_jobs(sha: LIVE_SHA, branch: "feat/ci-live-demo", passed: 4, pending: 4)

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='task-card-ci-progress']", 1
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol']", 8
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol'][data-ci-check-state='passed']", 4
    # The stable morph target wraps the meter, so a live push can swap it with no reload.
    assert_select "#ci-progress-#{task.slug}", 1
  end

  test "[integration] a re-run RESETS the live count on the board — no duplication" do
    task = submitted_task(branch: "feat/ci-rerun-demo", pr: 88)
    seed_run(branch: "feat/ci-rerun-demo", sha: RERUN_SHA)
    # Attempt 1: eight checks completed green under run 1.
    seed_attempt(sha: RERUN_SHA, branch: "feat/ci-rerun-demo", run_id: 1, first_job_id: 6_000,
                 status: "completed", conclusion: "success")
    # A re-run (run 2) re-queues the SAME eight checks with new job_ids.
    seed_attempt(sha: RERUN_SHA, branch: "feat/ci-rerun-demo", run_id: 2, first_job_id: 7_000,
                 status: "in_progress", conclusion: nil)

    get deployments_path
    assert_response :success

    assert_equal 16, CiCheckJob.where(head_sha: RERUN_SHA).count, "both attempts persist as rows"
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol']", 8, "the board shows 8 checks, never 16"
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol'][data-ci-check-state='pending']", 8,
      "the re-run reset the meter to the fresh (latest) attempt"
  end

  test "[integration] a task with no PR shows no CI meter" do
    task = Task.create!(title: "no pr yet", stage: "building",
                        metadata: { "devops" => { "branch" => "feat/no-pr", "repositories" => ["mcritchie-studio"] } })

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='task-card-ci-progress']", 0
  end

  private

  def submitted_task(branch:, pr:)
    Task.create!(
      title: "ci meter demo #{SecureRandom.hex(2)}",
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
    passed.times  { |i| CiCheckJob.create!(repo: "amcritchie/mcritchie-studio", job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: "CI", name: "pass-#{i}", status: "completed", conclusion: "success") }
    pending.times { |i| CiCheckJob.create!(repo: "amcritchie/mcritchie-studio", job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: "CI", name: "wait-#{i}", status: "in_progress") }
  end

  # One attempt of eight distinctly-named checks — the re-run mints a second with
  # the SAME names but new job_ids + run_id.
  def seed_attempt(sha:, branch:, run_id:, first_job_id:, status:, conclusion:)
    8.times do |i|
      CiCheckJob.create!(repo: "amcritchie/mcritchie-studio", job_id: first_job_id + i, run_id: run_id,
                         head_sha: sha, head_branch: branch, workflow_name: "CI",
                         name: "check-#{i}", status: status, conclusion: conclusion)
    end
  end
end
