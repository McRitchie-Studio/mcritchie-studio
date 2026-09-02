# frozen_string_literal: true

require "test_helper"

# [integration] The three states a reader must be able to tell apart, end-to-end
# through the real controller preloads and the real _board / _task_card / show
# partials: a FRESH build, a RESUBMISSION whose head has not moved, and a
# RESUBMISSION that addressed the feedback.
#
# The defect these cover: a `--kind rework` block leaves the task on `building`, so
# `bin/task list --stage blocked` returns zero and blocked_at / block_kind are null BY
# DESIGN. Every board surface therefore drew a bounced task and a never-reviewed one
# identically, and a task was measured being re-promoted to `submitted` — with a
# reviewer briefed that a merge-ready verdict was on record — while the circuit
# breaker read TRIPPED and the head had not moved since the send-back.
class TaskResubmissionVisibilityTest < ActionDispatch::IntegrationTest
  BOUNCE_AT = Time.utc(2026, 9, 2, 14, 3, 57)

  setup do
    GithubWorkflowRun.delete_all
    Activity.delete_all
  end

  # ── BOARD ────────────────────────────────────────────────────────────────────

  test "a FRESH building card carries no resubmission bar" do
    task = build_task("integration fresh build")
    seed_run(task, sha: "aaaa1111", at: BOUNCE_AT - 1.hour)

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='resubmission-state']", count: 0
  end

  test "a resubmission with an UNMOVED head is called out on the board" do
    task = build_task("integration unmoved head")
    seed_run(task, sha: "029a945b", at: BOUNCE_AT - 10.minutes)
    bounce!(task)

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='resubmission-state']" do |elements|
      assert_includes elements.first.text, "FEEDBACK NOT ADDRESSED"
    end
  end

  test "a resubmission that addressed the feedback reads differently from one that did not" do
    unmoved = build_task("integration still unmoved")
    seed_run(unmoved, sha: "029a945b", at: BOUNCE_AT - 10.minutes)
    bounce!(unmoved)

    moved = build_task("integration head has moved")
    seed_run(moved, sha: "029a945b", at: BOUNCE_AT - 10.minutes)
    bounce!(moved)
    seed_run(moved, sha: "bbbb2222", at: BOUNCE_AT + 20.minutes)

    get tasks_path
    assert_response :success

    unmoved_bar = css_select("#card-#{unmoved.slug} [data-test='resubmission-state']").first
    moved_bar = css_select("#card-#{moved.slug} [data-test='resubmission-state']").first

    assert unmoved_bar
    assert moved_bar
    assert_not_equal unmoved_bar.text.strip, moved_bar.text.strip,
                     "the whole acceptance criterion: these two must not read the same"
    assert_includes unmoved_bar.text, "NOT ADDRESSED"
    assert_not_includes moved_bar.text, "NOT ADDRESSED"
  end

  # ── TASK PAGE ────────────────────────────────────────────────────────────────

  test "the task page states the resubmission AND the circuit breaker's state" do
    task = build_task("integration task page banner")
    seed_run(task, sha: "029a945b", at: BOUNCE_AT - 10.minutes)
    bounce!(task)

    get task_path(task.slug)
    assert_response :success

    assert_select "[data-test='task-resubmission'][data-state='unaddressed']"
    assert_select "[data-test='task-resubmission-label']" do |els|
      assert_includes els.first.text, "FEEDBACK NOT ADDRESSED"
    end
    # What `bin/task bounces` knows, where a reader actually looks — it was the one
    # source that stayed correct while every field on this page read clear.
    assert_select "[data-test='task-breaker-state']" do |els|
      assert_includes els.first.text, "BREAKER ARMED"
      assert_includes els.first.text, "1 send-back"
    end
    assert_select "[data-test='task-resubmission-heads']" do |els|
      assert_includes els.first.text, "029a945b"
    end
  end

  test "the task page banner is ABSENT on a fresh build" do
    task = build_task("integration page fresh build")
    seed_run(task, sha: "aaaa1111", at: BOUNCE_AT - 1.hour)

    get task_path(task.slug)
    assert_response :success

    assert_select "[data-test='task-resubmission']", count: 0
  end

  # THE MEASURED FALSE CLEAR. Every prose field reads clear — a `--resolves-feedback`
  # handoff closed the qa_feedback, and a rework block never set blocked_at — while
  # the head never moved. This is the read that promoted a task into review on the
  # very tree a reviewer had bounced.
  test "the task page still warns when the prose says resolved but the head never moved" do
    task = build_task("integration hollow resolution")
    seed_run(task, sha: "029a945b", at: BOUNCE_AT - 10.minutes)
    bounce!(task)
    Activity.create!(task_slug: task.slug, activity_type: "handoff",
                     description: "Addressed and reshipped.",
                     metadata: { "resolves_feedback" => true },
                     created_at: BOUNCE_AT + 5.minutes, updated_at: BOUNCE_AT + 5.minutes)

    assert_not task.reload.unresolved_feedback?, "premise: the prose fields read CLEAR"
    assert_nil task.blocked_at, "premise: a rework block leaves blocked_at null"

    get task_path(task.slug)
    assert_response :success

    assert_select "[data-test='task-resubmission'][data-state='unaddressed']",
                  { count: 1 }, "the head is the honest signal; a resolution claim must not silence it"
  end

  # ── API — what an agent reads ────────────────────────────────────────────────

  test "the task API serves the resubmission verdict beside unresolved_feedback" do
    task = build_task("integration api verdict")
    seed_run(task, sha: "029a945b", at: BOUNCE_AT - 10.minutes)
    bounce!(task)

    get "/api/v1/tasks/#{task.slug}", headers: api_headers
    assert_response :success

    verdict = JSON.parse(response.body).dig("data", "resubmission")
    assert verdict, "an agent reading the task record must get this without knowing to run bin/task bounces"
    assert_equal "unaddressed", verdict["state"]
    assert_equal 1, verdict["bounce_count"]
    assert_equal true, verdict["breaker_tripped"]
    assert_equal "029a945b", verdict["head_at_bounce"]
    assert_equal "029a945b", verdict["head_now"]
  end

  test "the API reports a fresh build as fresh, with the breaker disarmed" do
    task = build_task("integration api fresh")

    get "/api/v1/tasks/#{task.slug}", headers: api_headers
    assert_response :success

    verdict = JSON.parse(response.body).dig("data", "resubmission")
    assert_equal "fresh", verdict["state"]
    assert_equal false, verdict["breaker_tripped"]
    assert_equal false, verdict["resubmission"]
  end

  private

  def api_headers
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)
    { "Authorization" => "Bearer #{token}" }
  end

  def build_task(title)
    Task.create!(
      title: title, stage: "building",
      metadata: { "devops" => {
        "branch" => "feat/#{title.parameterize}",
        "repositories" => ["mcritchie-studio"],
        "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/513"
      } }
    )
  end

  def seed_run(task, sha:, at:)
    GithubWorkflowRun.create!(
      repo: "McRitchie-Studio/mcritchie-studio", workflow_name: GithubWorkflowRun::CI_WORKFLOW,
      run_id: SecureRandom.random_number(10**12), status: "completed", conclusion: "success",
      head_branch: task.devops_field("branch"), head_sha: sha, run_started_at: at, created_at: at
    )
  end

  def bounce!(task)
    Activity.create!(
      task_slug: task.slug, activity_type: "qa_feedback",
      description: "The sibling's both-copies claims survive the change.",
      metadata: { "kind" => "rework", "summary" => "Sibling both-copies claims survive" },
      created_at: BOUNCE_AT, updated_at: BOUNCE_AT
    )
  end
end
