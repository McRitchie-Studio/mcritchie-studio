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
  GEM_SHA = "gem-head-sha".freeze
  GEM_RED_SHA = "gem-red-head-sha".freeze
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

  test "[integration] the meter draws a mark per check INSIDE the rail, in a linked card" do
    task = submitted_task(branch: "feat/ci-progress-demo", pr: 42)
    seed_run(branch: "feat/ci-progress-demo", sha: TASK_SHA)

    get deployments_path
    assert_response :success

    # A distinct bordered panel within the task card, AND the PR link.
    card = "#card-#{task.slug} a.ci-progress-card.border[data-test='task-card-ci-progress']"
    assert_select "#{card}[href='https://github.com/McRitchie-Studio/mcritchie-studio/pull/42'][target='_blank'][rel='noopener']", 1
    # The label reads the PR NUMBER off that same url — the operator's handle for it.
    assert_select "#card-#{task.slug} [data-test='task-ci-progress-label']", text: "PR: 42"
    # One mark per check, and they live INSIDE the progressbar rail, not above it.
    rail = "#card-#{task.slug} [role='progressbar'][aria-valuemax='8']"
    assert_select rail, 1
    assert_select "#{rail} [data-test='ci-check-symbol']", 8, "one mark per check, inside the bar"
    assert_select "#{rail} [data-test='ci-check-symbol'][data-ci-check-state='pending']", 2
  end

  test "[integration] a large suite draws marks too — it no longer falls back to X / Y" do
    task = submitted_task(branch: "feat/ci-many-demo", pr: 43)
    seed_run(branch: "feat/ci-many-demo", sha: MANY_SHA)

    get deployments_path
    assert_response :success

    within = "#card-#{task.slug} [data-test='task-card-ci-progress']"
    assert_select "#{within} [role='progressbar'][aria-valuenow='9'][aria-valuemax='14']", 1
    # 14 checks against a MEASURED cap of 13: the row draws what fits and says so, and
    # the fade is what makes the cut visible instead of a silent clip at the rail edge.
    assert_select "#{within} [data-test='ci-check-symbol']", ApplicationHelper::CI_METER_MARK_CAP
    assert_select "#{within} [data-test='task-ci-progress-marks'][data-overflowed='true']", 1
    assert_select "#card-#{task.slug} [data-test='task-ci-progress-fraction']", 0, "the numeric fallback is retired"
  end

  test "[integration] the Next Release card shows each member repo's G3 CI in its Assembling meter" do
    rel = Release.open! # the active candidate -> Release.current -> the Next Release card
    rel.add(Task.create!(title: "Hub release CI member", stage: "reviewed",
                         metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }))
    seed_run(branch: Release::BRANCH, sha: RELEASE_SHA)

    get deployments_path
    assert_response :success

    # G3 CI is now the ASSEMBLING meter of the repo's lane: fully green (8/8) -> done, with
    # a mark per check drawn inside its bar. The retired standalone "<repo> G3 tests" slot
    # is gone.
    hub = "#current-release [data-test='release-lane'][data-repo='mcritchie-studio']"
    assert_select "#{hub} [data-phase='assembling'][data-state='done']", 1
    assert_select "#{hub} [data-phase='assembling'] [data-test='release-phase-checks']", 1
    assert_select "#current-release [data-test='release-card-ci-progress-mcritchie-studio']", 0,
      "the standalone G3 slot no longer renders — CI lives in the Assembling meter"
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

  test "[integration] a BUILDING card shows its PR CI while bin/ship waits on it" do
    # The gate-submit-on-green-ci window: the PR is open and CI is running, but the
    # task is still on the builder's desk. This is the state the operator watches.
    task = building_task(branch: "feat/ci-building-demo", pr: 55)
    seed_run(branch: "feat/ci-building-demo", sha: LIVE_SHA)
    seed_jobs(sha: LIVE_SHA, branch: "feat/ci-building-demo", passed: 5, pending: 3)

    get deployments_path
    assert_response :success

    card = "#card-#{task.slug} a.ci-progress-card[data-test='task-card-ci-progress']"
    assert_select "#{card}[href='https://github.com/McRitchie-Studio/mcritchie-studio/pull/55']", 1
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol']", 8
    assert_select "#card-#{task.slug} [data-test='ci-check-symbol'][data-ci-check-state='passed']", 5
    assert_select "#ci-progress-#{task.slug}", 1, "the morph target exists so the meter ticks up live"
  end

  test "[integration] a live workflow_job fans out to the BUILDING card's meter" do
    task = building_task(branch: "feat/ci-building-live", pr: 56)
    seed_run(branch: "feat/ci-building-live", sha: LIVE_SHA)
    seed_jobs(sha: LIVE_SHA, branch: "feat/ci-building-live", passed: 2, pending: 6)

    affected = Ci::ProgressReader.new
                                 .eligible_tasks_for("McRitchie-Studio/mcritchie-studio", "feat/ci-building-live")

    assert_includes affected.map(&:slug), task.slug,
                    "a building task with an open PR is a live-broadcast target, not just submitted ones"
  end

  test "[integration] a task with no PR shows no CI meter" do
    task = Task.create!(title: "no pr yet", stage: "building",
                        metadata: { "devops" => { "branch" => "feat/no-pr", "repositories" => ["mcritchie-studio"] } })

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='task-card-ci-progress']", 0
  end

  test "[integration] a reviewed task hides the CI meter — its CI is in the past" do
    task = submitted_task(branch: "feat/ci-reviewed-demo", pr: 99)
    seed_run(branch: "feat/ci-reviewed-demo", sha: TASK_SHA)
    task.update!(stage: "reviewed") # same PR + CI run, but the meter is now stale noise

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='task-card-ci-progress']", 0
    assert_select "#ci-progress-#{task.slug}", 0, "the whole stable slot is gone once past submitted"
  end

  # THE GEM TASK CARD, end to end. A gem repo's suite is its own workflow
  # ("Engine CI"); the task path used to resolve its sha with the app literal "CI",
  # so a studio-engine card rendered NO meter at all. Live on 2026-08-25:
  # `polish-style-guide-modals` (studio-engine PR #195) drew nothing while
  # turf-monster PR #413 — same stage, same fields — drew its marks, and the blank
  # was diagnosed as an unwired webhook. The repo had 892 ingested runs.

  test "[integration] a GEM task card draws its Engine CI meter" do
    task = gem_task(branch: "feat/gem-board-meter", pr: 195)
    seed_gem_run(branch: "feat/gem-board-meter", sha: GEM_SHA, workflow: "Engine CI")
    seed_gem_jobs(sha: GEM_SHA, branch: "feat/gem-board-meter", workflow: "Engine CI",
                  passed: 3, failed: 0)

    get deployments_path
    assert_response :success

    within = "#card-#{task.slug} [data-test='task-card-ci-progress']"
    assert_select within, 1, "a gem task card must draw a meter, not a blank space"
    assert_select "#card-#{task.slug} [data-test='task-ci-progress-label']", text: "PR: 195"
    assert_select "#{within} [data-test='ci-check-symbol']", 3
  end

  test "[integration] a red sibling lane colours the GEM card's meter" do
    # The card must agree with Ci::ReviewGate, which folds EVERY run on the head.
    # Scoped to Engine CI alone this card would draw a green 3/3 on a task the gate
    # holds :red — the exact green-on-red lie the sibling fold exists to prevent.
    task = gem_task(branch: "feat/gem-board-red", pr: 196)
    seed_gem_run(branch: "feat/gem-board-red", sha: GEM_RED_SHA, workflow: "Engine CI")
    seed_gem_jobs(sha: GEM_RED_SHA, branch: "feat/gem-board-red", workflow: "Engine CI",
                  passed: 3, failed: 0)
    GithubWorkflowRun.create!(
      repo: ENGINE_NWO, workflow_name: "Consumer CI",
      run_id: SecureRandom.random_number(10**12), status: "completed", conclusion: "failure",
      head_branch: "feat/gem-board-red", head_sha: GEM_RED_SHA, run_started_at: Time.current
    )

    get deployments_path
    assert_response :success

    within = "#card-#{task.slug} [data-test='task-card-ci-progress']"
    assert_select "#{within} .ci-progress-meter[data-ci-state='red']", 1,
                  "a failing Consumer CI must show as red on the card, not hide behind a green Engine CI"
    assert_select "#{within} [data-test='ci-check-symbol'][data-ci-check-state='failed']", 1
  end

  private

  def submitted_task(branch:, pr:)
    Task.create!(
      title: "ci meter demo #{SecureRandom.hex(2)}",
      stage: "submitted",
      metadata: { "devops" => {
        "branch" => branch,
        "repositories" => ["mcritchie-studio"],
        "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/#{pr}"
      } }
    )
  end

  # Same shape as submitted_task, one stage earlier — the ship-wait desk.
  def building_task(branch:, pr:)
    submitted_task(branch: branch, pr: pr).tap { |task| task.update!(stage: "building") }
  end

  def seed_run(branch:, sha:)
    GithubWorkflowRun.create!(
      repo: "McRitchie-Studio/mcritchie-studio", workflow_name: "CI",
      run_id: SecureRandom.random_number(10**12), status: "in_progress",
      head_branch: branch, head_sha: sha, run_started_at: Time.current
    )
  end

  ENGINE_NWO = "McRitchie-Studio/studio-engine".freeze

  def gem_task(branch:, pr:)
    Task.create!(
      title: "gem ci meter #{SecureRandom.hex(2)}",
      stage: "submitted",
      metadata: { "devops" => {
        "branch" => branch,
        "repositories" => ["studio-engine"],
        "pr_url" => "https://github.com/McRitchie-Studio/studio-engine/pull/#{pr}"
      } }
    )
  end

  def seed_gem_run(branch:, sha:, workflow:)
    GithubWorkflowRun.create!(
      repo: ENGINE_NWO, workflow_name: workflow,
      run_id: SecureRandom.random_number(10**12), status: "in_progress",
      head_branch: branch, head_sha: sha, run_started_at: Time.current
    )
  end

  def seed_gem_jobs(sha:, branch:, workflow:, passed:, failed:)
    id = SecureRandom.random_number(10**12)
    passed.times { |i| CiCheckJob.create!(repo: ENGINE_NWO, job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: workflow, name: "engine-pass-#{i}", status: "completed", conclusion: "success") }
    failed.times { |i| CiCheckJob.create!(repo: ENGINE_NWO, job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: workflow, name: "engine-fail-#{i}", status: "completed", conclusion: "failure") }
  end

  def seed_jobs(sha:, branch:, passed:, pending:)
    id = SecureRandom.random_number(10**12)
    passed.times  { |i| CiCheckJob.create!(repo: "McRitchie-Studio/mcritchie-studio", job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: "CI", name: "pass-#{i}", status: "completed", conclusion: "success") }
    pending.times { |i| CiCheckJob.create!(repo: "McRitchie-Studio/mcritchie-studio", job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: "CI", name: "wait-#{i}", status: "in_progress") }
  end

  # One attempt of eight distinctly-named checks — the re-run mints a second with
  # the SAME names but new job_ids + run_id.
  def seed_attempt(sha:, branch:, run_id:, first_job_id:, status:, conclusion:)
    8.times do |i|
      CiCheckJob.create!(repo: "McRitchie-Studio/mcritchie-studio", job_id: first_job_id + i, run_id: run_id,
                         head_sha: sha, head_branch: branch, workflow_name: "CI",
                         name: "check-#{i}", status: status, conclusion: conclusion)
    end
  end
end
