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

  test "stage_lane buckets each stage into its own compartment" do
    assert_equal %i[build build build], %w[designed building submitted].map { |s| stage_lane(s) }
    assert_equal :review, stage_lane("reviewed")
    assert_equal :assembled, stage_lane("assembled")
    assert_equal :shipped, stage_lane("shipped")
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

  test "actor-less assembled / shipped fall back to their canonical role owners (Steffon / Avi)" do
    # A conductor/model move records only the spine (blank actor); the Deploy crew
    # must still show who OWNS the stage by role — Steffon QAs assembled, Avi ships —
    # so they never go faceless. (A PRESENT but unresolved actor is NOT overridden;
    # see the session-id stand-in test below.)
    groups = stage_agent_groups(deploy_task(stage: "shipped", reviewers: nil, assembled_actor: nil, shipped_actor: nil), @agents)

    assert_equal %w[assembled shipped], groups.map(&:stage)
    assert_equal %w[steffon avi], groups.map { |g| g.agent&.slug }
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

  # --- crew_clusters (board-card collapsing) ----------------------------------

  test "crew_clusters collapses the build lane to one circle with total build time once submitted" do
    task = Task.create!(title: "crew clusters build task", stage: "submitted")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 5.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 4.hours.ago, seconds_in_from: 1800, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600, actor: "carl")

    build = crew_clusters(task.reload, stage_agent_groups(task, @agents)).find { |c| c.lane == :build }

    assert_equal 3, build.stacked.size, "all three build stages stack into one circle"
    assert_equal 5400, build.seconds, "total build time = 1800 + 3600"
    assert_nil build.live_since, "not live once submitted"
  end

  test "crew_clusters marks the build lane live while still building" do
    task = Task.create!(title: "crew clusters live task", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, actor: "carl")

    build = crew_clusters(task.reload, stage_agent_groups(task, @agents)).find { |c| c.lane == :build }

    assert_not_nil build.live_since, "a building task ticks a live counter"
    assert_nil build.seconds, "no static build time until submitted"
  end

  test "crew_clusters keeps review heavy-on-top and splits assembled/shipped with their own time" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS) # reviewed 3600, assembled 1800, shipped 600
    clusters = crew_clusters(task, stage_agent_groups(task, @agents))
    review = clusters.find { |c| c.lane == :review }
    assembled = clusters.find { |c| c.lane == :assembled }
    shipped = clusters.find { |c| c.lane == :shipped }

    assert review.stacked.last.heavy?, "heavy reviewer is on top (rendered last)"
    assert_equal 3600, review.seconds, "the longer of the two reviews"
    assert_equal 1800, assembled.seconds, "Steffon's assembled time stands alone"
    assert_equal 600, shipped.seconds, "Avi's ship time stands alone"
  end

  # --- crew_columns (board-aware: Build splits, Deploy collapses; 3 vs 4 cols) -

  test "crew_columns on the Build board splits into three build steps, no QA spots" do
    task = Task.create!(title: "crew columns build split", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "shannon")

    cols = crew_columns(task.reload, stage_agent_groups(task, @agents), board: :build)

    assert_equal %i[designed building submitted], cols.map(&:lane), "three build steps, no QA"
    assert cols[0].stacked.any?, "designed step is filled"
    assert cols[1].stacked.any?, "building step is filled"
    assert_empty cols[2].stacked, "submitted not reached → blank reserved column"
    assert_equal 3600, cols[0].seconds, "designed shows the time spent in designed"
    assert cols[1].live_since, "the current step (building) ticks live"
  end

  test "crew_columns on the Deploy board is three columns until shipped, four once shipped" do
    assembled = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    assert_equal %i[build review assembled],
                 crew_columns(assembled, stage_agent_groups(assembled, @agents), board: :deploy).map(&:lane)

    shipped = deploy_task(stage: "shipped", reviewers: REVIEWERS)
    assert_equal %i[build review assembled shipped],
                 crew_columns(shipped, stage_agent_groups(shipped, @agents), board: :deploy).map(&:lane)
  end

  test "crew_columns gives a blocked task Assembled's three columns" do
    task = Task.create!(title: "crew columns blocked task", stage: "blocked")
    cols = crew_columns(task, stage_agent_groups(task, @agents), board: :deploy)
    assert_equal %i[build review assembled], cols.map(&:lane), "blocked mirrors Assembled (build · review · assembled)"
  end

  test "crew_columns splits the build steps for designed/building even on the Deploy board" do
    task = Task.create!(title: "crew columns deploy design", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "shannon")

    cols = crew_columns(task.reload, stage_agent_groups(task, @agents), board: :deploy)

    assert_equal %i[designed building submitted], cols.map(&:lane), "build steps show even on the deploy board"
  end

  # --- stage_timeline (consolidated /tasks/:id timeline) ----------------------

  test "stage_timeline yields one block per transition with the completing crew + usage" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS)
    blocks = stage_timeline(task, @agents)

    assert_equal %w[reviewed assembled shipped], blocks.reject(&:in_progress?).map(&:to_stage),
                 "one block per completed transition, newest last"
    shipped = blocks.find { |b| b.to_stage == "shipped" }
    assert_equal %w[avi], shipped.agents.map { |a| a.agent&.slug }
    assert_equal 600, shipped.seconds
  end

  test "stage_timeline backfills Steffon/Avi on actor-less assembled/shipped blocks" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS, assembled_actor: nil, shipped_actor: nil)
    by_stage = stage_timeline(task, @agents).index_by(&:to_stage)

    assert_equal %w[steffon], by_stage["assembled"].agents.map { |a| a.agent&.slug }
    assert_equal %w[avi], by_stage["shipped"].agents.map { |a| a.agent&.slug }
  end

  test "stage_timeline appends a live in-progress block for an open review intent" do
    task = Task.create!(title: "timeline live review task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    live = stage_timeline(task.reload, @agents).find(&:in_progress?)

    assert_not_nil live, "an open review intent surfaces as a live block"
    assert_equal "reviewed", live.to_stage
    assert_not_nil live.live_since
    assert_equal %w[shannon carl], live.agents.map { |a| a.agent&.slug }
    assert_equal %w[heavy light], live.agents.map(&:weight)
  end

  test "stage_timeline build-lane mascot wears its type (signature) color, not the name palette" do
    # Dragon (rarer) outranks Flying, so Dragonite's signature color is Dragon's.
    Studio::Enumeral.create!(category: "pokemon_type", key: "dragon", color: "#6F35FC", rank: 1500)
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying", color: "#A98FF3", rank: 400)
    mon = Pokemon.create!(dex: 149, name: "Dragonite", slug: "dragonite", generation: 1,
                          types: %w[dragon flying], sprite_url: "https://example.test/dragonite-sprite.png")
    assert_equal "#6F35FC", mon.signature_color, "guard: the seeded mascot has a type color"

    task = Task.create!(title: "timeline mascot color task", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 2.hours.ago, actor: "carl")

    block = stage_timeline(task.reload, @agents, mascot: mon).find { |b| b.to_stage == "designed" }
    avatar_color = block.agents.first.avatar_color

    # The consolidated /tasks/:id timeline must match the build board: the mascot
    # wears its signature TYPE color, not the name-derived palette fallback.
    assert_equal "#6F35FC", avatar_color, "the timeline mascot wears its type color"
    assert_not_includes Agent::AVATAR_COLORS, avatar_color, "not the name-palette fallback"
  end

  # --- in_progress_work + the board live injection ----------------------------

  test "in_progress_work reads the Steffon QA intent while reviewed" do
    task = Task.create!(title: "qa intent task", stage: "reviewed")
    task.record_intent_event(to_stage: "assembled", actor: "steffon")
    work = in_progress_work(task.reload, @by_slug, nil, task.task_events.select(&:intent?))

    assert_equal :assembled, work[:lane]
    assert_equal %w[steffon], work[:agents].map { |a| a.agent&.slug }
    assert_not_nil work[:live_since]
  end

  test "in_progress_work returns nil for a shipped (idle) task" do
    assert_nil in_progress_work(deploy_task(stage: "shipped", reviewers: REVIEWERS), @by_slug, nil, [])
  end

  test "crew_columns surfaces an open review intent as a live ticking cluster on the deploy board" do
    task = Task.create!(title: "board live review task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    task.reload

    review = crew_columns(task, stage_agent_groups(task, @agents), board: :deploy, agents: @agents)
            .find { |c| c.lane == :review }

    assert review.stacked.any?, "the review lane shows the in-progress pair"
    assert_not_nil review.live_since, "and ticks a live counter"
  end

  test "crew_columns without an agent map skips the live injection (legacy callers unchanged)" do
    task = Task.create!(title: "board no-agents task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    task.reload

    review = crew_columns(task, stage_agent_groups(task, @agents), board: :deploy).find { |c| c.lane == :review }
    assert_empty review.stacked, "no agents passed → no live cluster, exactly as before"
  end
end
