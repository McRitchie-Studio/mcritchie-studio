require "test_helper"

# [integration] The orchestrator seat works end to end under `ray`: heartbeat
# attribution lands on it through the API, reviewer selection seats and excludes
# it, the legacy `alex` slug rides the alias into both, and the seat's pages
# answer under /ray.
class RaySeatTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  fixtures :agents

  # ── Heartbeat attribution ────────────────────────────────────────────────

  test "an activity opened as ray attributes to the seat, and one opened as alex lands on the same seat" do
    ray = AgentActivity.create!(session_id: "seat-x", category: "Explore", reason_slug: "orient", opened_at: Time.current,
                                agent: "ray")
    legacy = AgentActivity.create!(session_id: "seat-a", category: "Explore", reason_slug: "orient", opened_at: Time.current,
                                   agent: "alex")

    assert_equal "ray", ray.reload.agent
    assert_equal "ray", legacy.reload.agent, "the sticky marker of a pre-rename session still reaches the seat"
  end

  test "the bearer grade path grades as ray and awaiting_grade is keyed the same way" do
    span = AgentActivity.create!(session_id: "seat-g", category: "Verify", reason_slug: "prove it",
                                 opened_at: 1.minute.ago, closed_at: Time.current, outcome_slug: "green")
    assert_includes AgentActivity.awaiting_grade.map(&:id), span.id

    grade = ActionGrade.record_activity_grade(activity: span, grader: ActionGrade::RAY, disposition: "good",
                                              slug: "a clean seat under ray")

    assert_equal "ray", grade.grader
    refute_includes AgentActivity.awaiting_grade.map(&:id), span.id, "graded under ray, so no longer awaiting"
    assert_includes AgentActivity.awaiting_grade(grader: "mcr").map(&:id), span.id, "the audit row is still owed"
  end

  # ── Reviewer selection ───────────────────────────────────────────────────

  def task_for(shape:, devops: {})
    Task.create!(title: "ray seat sample", stage: "submitted",
                 metadata: { "devops" => { "shape" => shape }.merge(devops) })
  end

  def light_of(decision) = decision["reviewers"].find { |r| r["weight"] == "light" }&.fetch("slug")

  test "a docs-shaped task seats ray as the light" do
    decision = ReviewerSelector.new(task_for(shape: "docs")).decision

    assert_equal "carl", decision["reviewers"].find { |r| r["weight"] == "primary" }["slug"]
    assert_equal "ray", light_of(decision), "the Documentation seat is ray's"
    refute_includes decision["candidates"], "alex", "the retired slug is never a candidate"
  end

  test "an author recorded as alex keeps ray out of the pool" do
    task = task_for(shape: "docs")
    task.update_columns(metadata: { "devops" => { "shape" => "docs", "built_by" => "alex", "builders" => %w[alex] } })

    decision = ReviewerSelector.new(task).decision

    assert_equal %w[ray], decision["builders"], "the record reads through the alias"
    refute_includes decision["candidates"], "ray", "ray cannot review the diff alex wrote — same soul"
    refute_equal "ray", light_of(decision)
  end

  test "--busy alex and --builder alex both resolve to ray" do
    task = task_for(shape: "docs")

    busy = ReviewerSelector.new(task, busy: %w[alex]).decision
    assert_includes busy["excluded_busy"], "ray"

    override = ReviewerSelector.new(task, builder: "steffon,alex").decision
    assert_equal %w[steffon ray], override["builders"]
    refute_includes override["candidates"], "ray"
  end

  # ── Routes: /ray/* serves, /alex/* forwards ──────────────────────────────

  test "the seat's pages answer under /ray" do
    assert_equal "/ray/heartbeat", ray_heartbeat_path
    assert_equal "/ray/insights", ray_insights_path
    assert_equal "/ray/pipeline", ray_pipeline_path
    assert_routing "/ray/heartbeat", controller: "heartbeat", action: "show"
    assert_routing "/ray/insights", controller: "heartbeat", action: "insights"

    get ray_heartbeat_path
    assert_response :success
    get ray_insights_path
    assert_response :success
  end

  test "the launcher enters the seat as ray" do
    get launcher_path
    assert_response :success
    assert_select "a[data-avenue=ray][href=?]", ray_heartbeat_path
    assert_select "[data-avenue=alex]", 0
  end
end
