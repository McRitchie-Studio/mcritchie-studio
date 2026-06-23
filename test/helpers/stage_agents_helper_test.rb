require "test_helper"

class StageAgentsHelperTest < ActionView::TestCase
  setup do
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @carl    = Agent.create!(name: "Carl", slug: "carl")
    @steffon = Agent.create!(name: "Steffon", slug: "steffon", avatar: "https://example.com/steffon.png")
    @avi     = Agent.create!(name: "Avi", slug: "avi")
    @agents  = Agent.all.to_a
    @by_slug = @agents.index_by(&:slug)
  end

  # Build a Deploy-half task with explicit TaskEvents so the per-stage attribution
  # and durations are deterministic (seconds chosen distinct per stage).
  def deploy_task(stage:, reviewers: nil, assembled_actor: "steffon", shipped_actor: "avi")
    metadata = reviewers ? { "reviewers" => reviewers } : {}
    task = Task.create!(title: "deploy crew #{stage} task", stage: stage, metadata: metadata)
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600)
    if %w[assembled shipped].include?(stage)
      TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                        occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: assembled_actor)
    end
    if stage == "shipped"
      TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                        occurred_at: 1.hour.ago, seconds_in_from: 600, actor: shipped_actor)
    end
    task.reload
  end

  REVIEWERS = [{ "slug" => "shannon", "weight" => "heavy" }, { "slug" => "carl", "weight" => "light" }].freeze

  # --- resolve_actor_agent ----------------------------------------------------

  test "resolve_actor_agent matches an agent slug (case-insensitive)" do
    assert_equal @steffon, resolve_actor_agent("steffon", @by_slug)
    assert_equal @steffon, resolve_actor_agent("  STEFFON ", @by_slug)
  end

  test "resolve_actor_agent matches the local part of an email actor" do
    assert_equal @avi, resolve_actor_agent("avi@mcritchie.studio", @by_slug)
  end

  test "resolve_actor_agent returns nil for a session id or unknown actor" do
    assert_nil resolve_actor_agent("2aa216f6-7565-4bf4-bd01-70793c8ba617", @by_slug)
    assert_nil resolve_actor_agent("ghost", @by_slug)
    assert_nil resolve_actor_agent(nil, @by_slug)
    assert_nil resolve_actor_agent("", @by_slug)
  end

  # --- stage_agent_groups -----------------------------------------------------

  test "a shipped task yields 2 reviewers + steffon + avi with per-stage seconds" do
    groups = stage_agent_groups(deploy_task(stage: "shipped", reviewers: REVIEWERS), @agents)

    assert_equal %w[reviewed reviewed assembled shipped], groups.map(&:stage)
    assert_equal %w[shannon carl steffon avi], groups.map { |g| g.agent&.slug }
    assert_equal ["heavy", "light", nil, nil], groups.map(&:weight)
    # seconds_in_from of the event that COMPLETED each stage (reviewers share the
    # →reviewed event); 3600 = review, 1800 = assemble wait, 600 = QA wait
    assert_equal [3600, 3600, 1800, 600], groups.map(&:seconds)
  end

  test "an assembled task shows the 2 reviewers + steffon, but no avi" do
    groups = stage_agent_groups(deploy_task(stage: "assembled", reviewers: REVIEWERS), @agents)

    assert_equal %w[reviewed reviewed assembled], groups.map(&:stage)
    assert_equal %w[shannon carl steffon], groups.map { |g| g.agent&.slug }
  end

  test "reviewers absent yields no reviewer avatars even with a reviewed event" do
    groups = stage_agent_groups(deploy_task(stage: "assembled", reviewers: nil), @agents)

    # graceful: no reviewers metadata → only the assembled actor renders
    assert_equal %w[assembled], groups.map(&:stage)
    assert_equal %w[steffon], groups.map { |g| g.agent&.slug }
  end

  test "assembled / shipped events with no actor are skipped" do
    task = deploy_task(stage: "shipped", reviewers: nil, assembled_actor: nil, shipped_actor: nil)
    assert_empty stage_agent_groups(task, @agents)
  end

  test "an unresolved actor falls back to a palette stand-in without crashing" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS,
                       assembled_actor: "9f3ac1b2-session", shipped_actor: "avi")
    assembled = stage_agent_groups(task, @agents).find { |g| g.stage == "assembled" }

    assert_nil assembled.agent
    assert_equal "9f3ac1b2-session", assembled.label
    assert_equal "9", assembled.avatar_initials
    assert_includes Agent::AVATAR_COLORS, assembled.avatar_color
    assert_nil assembled.avatar
  end

  test "a Build-lane task (no deploy events) yields nothing" do
    task = Task.create!(title: "build lane crewless task", stage: "building")
    assert_empty stage_agent_groups(task, @agents)
  end

  test "the resolved reviewer carries its weight and from_label" do
    groups = stage_agent_groups(deploy_task(stage: "reviewed", reviewers: REVIEWERS), @agents)
    heavy = groups.first

    assert_equal @shannon, heavy.agent
    assert heavy.heavy?
    assert_equal "Submitted", heavy.from_label
    assert_equal 3600, heavy.seconds
  end
end
