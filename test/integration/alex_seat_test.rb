require "test_helper"

# [integration] The persona seat works end to end under `alex` (ritch-renamed-alex):
# heartbeat attribution lands on it, the legacy `ray` slug rides the alias, the
# learning heartbeat it held answers under /mason (Mason grades now), and every
# retired /ray and /xan page forwards there.
class AlexSeatTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  fixtures :agents

  # ── Heartbeat attribution ────────────────────────────────────────────────

  test "an activity opened as alex attributes to the seat, and one opened as ray lands on the same seat" do
    alex = AgentActivity.create!(session_id: "seat-x", category: "Explore", reason_slug: "orient", opened_at: Time.current,
                                agent: "alex")
    legacy = AgentActivity.create!(session_id: "seat-a", category: "Explore", reason_slug: "orient", opened_at: Time.current,
                                   agent: "ray")

    assert_equal "alex", alex.reload.agent
    assert_equal "alex", legacy.reload.agent, "the sticky marker of a pre-rename session still reaches the seat"
  end

  test "the bearer grade path grades as mason and awaiting_grade is keyed the same way" do
    span = AgentActivity.create!(session_id: "seat-g", category: "Verify", reason_slug: "prove it",
                                 opened_at: 1.minute.ago, closed_at: Time.current, outcome_slug: "green")
    assert_includes AgentActivity.awaiting_grade.map(&:id), span.id

    grade = ActionGrade.record_activity_grade(activity: span, grader: ActionGrade::MASON, disposition: "good",
                                              slug: "a clean seat under alex")

    assert_equal "mason", grade.grader
    refute_includes AgentActivity.awaiting_grade.map(&:id), span.id, "graded under mason, so no longer awaiting"
    assert_includes AgentActivity.awaiting_grade(grader: "mcr").map(&:id), span.id, "the audit row is still owed"
  end

  # ── Reviewer selection ───────────────────────────────────────────────────

  def task_for(shape:, devops: {})
    Task.create!(title: "alex seat sample", stage: "submitted",
                 metadata: { "devops" => { "shape" => shape }.merge(devops) })
  end

  def light_of(decision) = decision["reviewers"].find { |r| r["weight"] == "light" }&.fetch("slug")

  test "a docs-shaped task seats mason as the light, not alex" do
    decision = ReviewerSelector.new(task_for(shape: "docs")).decision

    assert_equal "carl", decision["reviewers"].find { |r| r["weight"] == "primary" }["slug"]
    assert_equal "mason", light_of(decision), "the Documentation seat is Mason's since 2026-10-25"
    refute_includes decision["candidates"], "alex", "the alex soul left the review pool"
    refute_includes decision["candidates"], "alex", "the retired slug is never a candidate"
  end

  test "an author recorded as alex keeps alex out of the pool" do
    task = task_for(shape: "docs")
    task.update_columns(metadata: { "devops" => { "shape" => "docs", "built_by" => "alex", "builders" => %w[alex] } })

    decision = ReviewerSelector.new(task).decision

    assert_equal %w[alex], decision["builders"], "the record reads through the alias"
    refute_includes decision["candidates"], "alex", "alex cannot review the diff alex wrote — same soul"
    refute_equal "alex", light_of(decision)
  end

  test "--busy alex and --builder alex both resolve to alex" do
    task = task_for(shape: "docs")

    busy = ReviewerSelector.new(task, busy: %w[alex]).decision
    refute_includes busy["excluded_busy"], "alex", "the retired slug never reaches the pool as itself"
    assert_equal "mason", light_of(busy), "busy alex is outside the pool, so the docs light stays Mason"

    override = ReviewerSelector.new(task, builder: "steffon,alex").decision
    assert_equal %w[steffon alex], override["builders"]
    refute_includes override["candidates"], "alex"
  end

  # ── Routes: /alex/* serves, /xan/* forwards ───────────────────────────────

  test "the seat's pages answer under /mason" do
    assert_equal "/mason/heartbeat", mason_heartbeat_path
    assert_equal "/mason/insights", mason_insights_path
    assert_equal "/mason/pipeline", mason_pipeline_path
    assert_routing "/mason/heartbeat", controller: "heartbeat", action: "show"
    assert_routing "/mason/insights", controller: "heartbeat", action: "insights"

    get mason_heartbeat_path
    assert_response :success
    get mason_insights_path
    assert_response :success
  end

  # The seat's slugs until 2026-10-18 (xan) and 2026-10-25 (ray): every old GET
  # 301s to the same page under /mason, query string included, so a bookmarked
  # deep link still lands.
  test "the retired /xan and /ray pages forward to /mason, query string and all" do
    {
      "/ray/heartbeat?session_id=abc"          => "/mason/heartbeat?session_id=abc",
      "/ray/heartbeat/activities/7/feedback"   => "/mason/heartbeat/activities/7/feedback",
      "/ray/insights"                          => "/mason/insights",
      "/ray/pipeline"                          => "/mason/pipeline",
      "/xan/heartbeat"                         => "/mason/heartbeat",
      "/xan/heartbeat?session_id=abc"          => "/mason/heartbeat?session_id=abc",
      "/xan/heartbeat/activities?page=2"       => "/mason/heartbeat/activities?page=2",
      "/xan/heartbeat/activities/7/feedback"   => "/mason/heartbeat/activities/7/feedback",
      "/xan/insights"                          => "/mason/insights",
      "/xan/pipeline"                          => "/mason/pipeline"
    }.each do |old, new|
      get old
      assert_response :moved_permanently, old
      assert_equal "http://www.example.com#{new}", response.location, old
    end
  end

  # The seat's agent page under its old slugs answered "Agent not found"
  # (rename-loose-ends). It held the orchestrator seat, which is Mason's now, so the
  # page forwards there. Only the bare page: /agents/ray/settings is not a shim,
  # and the persona's own page stays /agents/alex.
  test "the retired /agents/ray and /agents/xan pages forward to /agents/mason" do
    %w[/agents/ray /agents/xan].each do |old|
      get old
      assert_response :moved_permanently, old
      assert_equal "http://www.example.com/agents/mason", response.location, old
    end
  end

  test "the persona and the orchestrator keep their own agent pages" do
    get "/agents/mason"
    refute_equal 301, response.status
    get "/agents/alex"
    refute_equal 301, response.status
    refute_match %r{/agents/mason}, response.location.to_s
  end

  test "the launcher enters the learning heartbeat as mason, and no avenue names a retired slug" do
    get launcher_path
    assert_response :success
    assert_select "a[data-avenue=mason][href=?]", mason_heartbeat_path
    assert_select "[data-avenue=ray]", 0
    assert_select "[data-avenue=xan]", 0
  end
end
