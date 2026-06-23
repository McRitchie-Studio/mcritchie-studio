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
    task = Task.create!(title: "deploy crew #{stage} task", stage: stage)
    task.task_events.delete_all
    # Reviewers ride the →reviewed EVENT's metadata (the canonical write target,
    # per Task#stage_event_metadata) — NOT Task.metadata. The helper reads them
    # off the event, so the harness must seed them there too.
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600,
                      metadata: reviewers ? { "reviewers" => reviewers } : {})
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

  # --- stage_lane (board-card bunching) ---------------------------------------

  test "stage_lane buckets each stage into a build / review / deploy bunch" do
    assert_equal %i[build build build], %w[designed building submitted].map { |s| stage_lane(s) }
    assert_equal :review, stage_lane("reviewed")
    assert_equal %i[deploy deploy], %w[assembled shipped].map { |s| stage_lane(s) }
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

  # --- Build-lane attribution (designed / building / submitted) ---------------

  test "a Build-lane task whose events carry no actor yields nothing" do
    # genesis event (→building) has a blank actor (model-method create) → skipped
    task = Task.create!(title: "build lane crewless task", stage: "building")
    assert_empty stage_agent_groups(task, @agents)
  end

  test "a Build-lane task attributes each build event to its actor" do
    task = Task.create!(title: "build lane crewed task", stage: "submitted")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 3.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 1.hour.ago, seconds_in_from: 1800, actor: "shannon")

    groups = stage_agent_groups(task.reload, @agents)

    assert_equal %w[designed building submitted], groups.map(&:stage)
    assert_equal %w[carl shannon shannon], groups.map { |g| g.agent&.slug }
    assert_equal [nil, 3600, 1800], groups.map(&:seconds)
    assert_empty groups.map(&:weight).compact, "build entries carry no review weight"
  end

  test "build + deploy stages render together for a fully-shipped task" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS)
    # graft on the earlier build-lane events the deploy_task helper omits
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 6.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 5.hours.ago, seconds_in_from: 3600, actor: "shannon")

    groups = stage_agent_groups(task.reload, @agents)

    assert_equal %w[designed building reviewed reviewed assembled shipped], groups.map(&:stage)
    assert_equal %w[carl shannon shannon carl steffon avi], groups.map { |g| g.agent&.slug }
  end

  test "the most recent landing event wins when a stage is re-entered" do
    task = Task.create!(title: "build lane bounce task", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 3.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "blocked",
                      occurred_at: 2.hours.ago, actor: "avi")
    TaskEvent.create!(task_slug: task.slug, from_stage: "blocked", to_stage: "building",
                      occurred_at: 1.hour.ago, actor: "shannon")

    groups = stage_agent_groups(task.reload, @agents)

    # only the latest →building event contributes; blocked is not a crew stage
    assert_equal %w[building], groups.map(&:stage)
    assert_equal %w[shannon], groups.map { |g| g.agent&.slug }
  end

  test "the resolved reviewer carries its weight and from_label" do
    groups = stage_agent_groups(deploy_task(stage: "reviewed", reviewers: REVIEWERS), @agents)
    heavy = groups.first

    assert_equal @shannon, heavy.agent
    assert heavy.heavy?
    assert_equal "Submitted", heavy.from_label
    assert_equal 3600, heavy.seconds
  end

  # --- end-to-end seam: review! writes the pair to the EVENT, the avatars read it
  #
  # Regression for the reviewer→avatars seam bug: the engine records the pair on
  # the submitted→reviewed TaskEvent's metadata (NOT Task.metadata), but the
  # avatars reader pulled from task.reviewers (Task.metadata, the wrong record), so
  # the two senior avatars rendered nothing in prod. Drive the REAL write path
  # (review! → Task#stage_event_metadata via Current) through the helper so the
  # whole seam is exercised, not a hand-seeded record.
  test "review! records reviewers on the event and stage_agent_groups renders 2 seniors with heavy/light" do
    task = Task.create!(title: "seam review crew task", stage: "submitted")
    Current.task_event_reviewers = REVIEWERS
    task.review! # submitted→reviewed: writes the pair onto the new TaskEvent's metadata
    Current.task_event_reviewers = nil

    reviewed_event = task.task_events.find_by(to_stage: "reviewed")
    assert_equal REVIEWERS, reviewed_event.metadata["reviewers"],
                 "the pair must land on the →reviewed EVENT, not Task.metadata"
    assert_empty task.reload.metadata.fetch("reviewers", []),
                 "nothing is written to Task.metadata — the old (wrong) read source"

    avatars = stage_agent_groups(task, @agents).select { |g| g.stage == "reviewed" }

    assert_equal 2, avatars.size, "both senior reviewers must render off the event"
    assert_equal %w[shannon carl], avatars.map { |g| g.agent&.slug }
    assert_equal %w[heavy light], avatars.map(&:weight)
    assert avatars.first.heavy?, "the heavy reviewer keeps its heavy pill"
  end

  # --- Build-lane mascot (the task's Pokémon is the feature agent's face) -------

  test "build-lane stages wear the task mascot when one is given" do
    mon = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1,
                          sprite_url: "https://example.test/snorlax-sprite.png")
    task = Task.create!(title: "mascot build crew task", stage: "submitted")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 3.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 1.hour.ago, actor: "shannon")

    groups = stage_agent_groups(task.reload, @agents, mascot: mon)

    assert_equal %w[designed building submitted], groups.map(&:stage)
    assert_equal %w[Snorlax Snorlax Snorlax], groups.map(&:name), "every build stage wears the mascot"
    assert_equal ["https://example.test/snorlax-sprite.png"] * 3, groups.map(&:avatar)
  end

  test "build stages wear the mascot while deploy stages keep their real actors" do
    mon = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1,
                          sprite_url: "https://example.test/snorlax-sprite.png")
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS)
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 6.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 5.hours.ago, actor: "shannon")

    by_stage = stage_agent_groups(task.reload, @agents, mascot: mon).group_by(&:stage)

    # Build lane → the mascot
    assert_equal "Snorlax", by_stage["designed"].first.name
    assert_equal "https://example.test/snorlax-sprite.png", by_stage["building"].first.avatar
    # Deploy lane → the real crew, no mascot
    assert_equal %w[shannon carl steffon avi],
                 (by_stage["reviewed"] + by_stage["assembled"] + by_stage["shipped"]).map { |g| g.agent&.slug }
    assert_not_equal "https://example.test/snorlax-sprite.png", by_stage["shipped"].first.avatar
  end
end
