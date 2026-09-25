require "test_helper"

# [integration] The orchestrator seat works end to end under `xan`: heartbeat
# attribution lands on it through the API, reviewer selection seats and excludes
# it, the legacy `alex` slug rides the alias into both, and the /alex/* pages
# forward to /xan/* with their query strings intact.
class XanSeatTest < ActionDispatch::IntegrationTest
  fixtures :agents

  # ── Heartbeat attribution ────────────────────────────────────────────────

  test "an activity opened as xan attributes to the seat, and one opened as alex lands on the same seat" do
    xan = AgentActivity.create!(session_id: "seat-x", category: "Explore", reason_slug: "orient", opened_at: Time.current,
                                agent: "xan")
    legacy = AgentActivity.create!(session_id: "seat-a", category: "Explore", reason_slug: "orient", opened_at: Time.current,
                                   agent: "alex")

    assert_equal "xan", xan.reload.agent
    assert_equal "xan", legacy.reload.agent, "the sticky marker of a pre-rename session still reaches the seat"
  end

  test "the bearer grade path grades as xan and awaiting_grade is keyed the same way" do
    span = AgentActivity.create!(session_id: "seat-g", category: "Verify", reason_slug: "prove it",
                                 opened_at: 1.minute.ago, closed_at: Time.current, outcome_slug: "green")
    assert_includes AgentActivity.awaiting_grade.map(&:id), span.id

    grade = ActionGrade.record_activity_grade(activity: span, grader: ActionGrade::XAN, disposition: "good",
                                              slug: "a clean seat under xan")

    assert_equal "xan", grade.grader
    refute_includes AgentActivity.awaiting_grade.map(&:id), span.id, "graded under xan, so no longer awaiting"
    assert_includes AgentActivity.awaiting_grade(grader: "mcr").map(&:id), span.id, "the audit row is still owed"
  end

  # ── Reviewer selection ───────────────────────────────────────────────────

  def task_for(shape:, devops: {})
    Task.create!(title: "xan seat sample", stage: "submitted",
                 metadata: { "devops" => { "shape" => shape }.merge(devops) })
  end

  def light_of(decision) = decision["reviewers"].find { |r| r["weight"] == "light" }&.fetch("slug")

  test "a docs-shaped task seats xan as the light" do
    decision = ReviewerSelector.new(task_for(shape: "docs")).decision

    assert_equal "carl", decision["reviewers"].find { |r| r["weight"] == "primary" }["slug"]
    assert_equal "xan", light_of(decision), "the Documentation seat is xan's"
    refute_includes decision["candidates"], "alex", "the retired slug is never a candidate"
  end

  test "an author recorded as alex keeps xan out of the pool" do
    task = task_for(shape: "docs")
    task.update_columns(metadata: { "devops" => { "shape" => "docs", "built_by" => "alex", "builders" => %w[alex] } })

    decision = ReviewerSelector.new(task).decision

    assert_equal %w[xan], decision["builders"], "the record reads through the alias"
    refute_includes decision["candidates"], "xan", "xan cannot review the diff alex wrote — same soul"
    refute_equal "xan", light_of(decision)
  end

  test "--busy alex and --builder alex both resolve to xan" do
    task = task_for(shape: "docs")

    busy = ReviewerSelector.new(task, busy: %w[alex]).decision
    assert_includes busy["excluded_busy"], "xan"

    override = ReviewerSelector.new(task, builder: "steffon,alex").decision
    assert_equal %w[steffon xan], override["builders"]
    refute_includes override["candidates"], "xan"
  end

  # ── Routes: /xan/* serves, /alex/* forwards ──────────────────────────────

  test "the seat's pages answer under /xan" do
    assert_equal "/xan/heartbeat", xan_heartbeat_path
    assert_equal "/xan/insights", xan_insights_path
    assert_equal "/xan/pipeline", xan_pipeline_path
    assert_routing "/xan/heartbeat", controller: "heartbeat", action: "show"
    assert_routing "/xan/insights", controller: "heartbeat", action: "insights"

    get xan_heartbeat_path
    assert_response :success
    get xan_insights_path
    assert_response :success
  end

  test "the legacy /alex paths redirect permanently and keep their query string" do
    get "/alex/heartbeat?session_id=sess-A&page=2"
    assert_response :moved_permanently
    assert_equal "http://www.example.com/xan/heartbeat?session_id=sess-A&page=2", response.location

    get "/alex/heartbeat"
    assert_redirected_to "http://www.example.com/xan/heartbeat"

    get "/alex/heartbeat/activities?page=3"
    assert_response :moved_permanently
    assert_equal "http://www.example.com/xan/heartbeat/activities?page=3", response.location

    get "/alex/insights"
    assert_redirected_to "http://www.example.com/xan/insights"

    get "/alex/pipeline"
    assert_redirected_to "http://www.example.com/xan/pipeline"

    follow_redirect!
    assert_response :success, "the forward lands on a page that renders"
  end

  test "the launcher enters the seat as xan" do
    get launcher_path
    assert_response :success
    assert_select "a[data-avenue=xan][href=?]", xan_heartbeat_path
    assert_select "[data-avenue=alex]", 0
  end
end
