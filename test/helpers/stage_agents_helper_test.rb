require "test_helper"

class StageAgentsHelperTest < ActionView::TestCase
  # The rendered-partial (component) tests reach ApplicationHelper for the corner
  # duration pill (compact_stage_duration); make it available to the view context.
  helper ApplicationHelper

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
  def deploy_task(stage:, reviewers: nil, assembled_actor: "avi", shipped_actor: "steffon")
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

  REVIEWERS = [{ "slug" => "shannon", "weight" => "primary" }, { "slug" => "carl", "weight" => "light" }].freeze

  # A task that walked designed → building → submitted → blocked wearing `slug`'s
  # mascot, with the block landing from `blocker`. Deterministic per-stage durations so
  # the design (420s) and build (2160s) slots carry stable corner pills.
  def blocked_journey_task(slug:, blocker:)
    # A block is a `building` attribute now — the blocker is the blocked_by column,
    # not a →blocked TaskEvent. The design/build/submit spine stays for slots 1/2.
    task = Task.create!(title: "blocked journey #{slug} task", stage: "building",
                        metadata: { "devops" => { "mascot" => slug } })
    task.block!(by: blocker, kind: "rework")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 3.hours.ago)
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 420)
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 90.minutes.ago, seconds_in_from: 2160)
    task.reload
  end

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

  test "a shipped task yields 2 reviewers + avi + steffon with per-stage seconds" do
    groups = stage_agent_groups(deploy_task(stage: "shipped", reviewers: REVIEWERS), @agents)

    assert_equal %w[reviewed reviewed assembled shipped], groups.map(&:stage)
    assert_equal %w[shannon carl avi steffon], groups.map { |g| g.agent&.slug }
    assert_equal ["primary", "light", nil, nil], groups.map(&:weight)
    # seconds_in_from of the event that COMPLETED each stage (reviewers share the
    # →reviewed event); 3600 = review, 1800 = assemble wait, 600 = QA wait
    assert_equal [3600, 3600, 1800, 600], groups.map(&:seconds)
  end

  test "an assembled task shows the 2 reviewers + avi, but no steffon" do
    groups = stage_agent_groups(deploy_task(stage: "assembled", reviewers: REVIEWERS), @agents)

    assert_equal %w[reviewed reviewed assembled], groups.map(&:stage)
    assert_equal %w[shannon carl avi], groups.map { |g| g.agent&.slug }
  end

  test "reviewers absent yields no reviewer avatars even with a reviewed event" do
    groups = stage_agent_groups(deploy_task(stage: "assembled", reviewers: nil), @agents)

    # graceful: no reviewers metadata → only the assembled actor renders
    assert_equal %w[assembled], groups.map(&:stage)
    assert_equal %w[avi], groups.map { |g| g.agent&.slug }
  end

  test "actor-less assembled / shipped fall back to their canonical role owners (Avi / Steffon)" do
    # A conductor/model move records only the spine (blank actor); the Deploy crew
    # must still show who OWNS the stage by role — Avi QAs assembled, Steffon ships —
    # so they never go faceless. (A PRESENT but unresolved actor is NOT overridden;
    # see the session-id stand-in test below.)
    groups = stage_agent_groups(deploy_task(stage: "shipped", reviewers: nil, assembled_actor: nil, shipped_actor: nil), @agents)

    assert_equal %w[assembled shipped], groups.map(&:stage)
    assert_equal %w[avi steffon], groups.map { |g| g.agent&.slug }
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
    assert_equal %w[carl shannon shannon carl avi steffon], groups.map { |g| g.agent&.slug }
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
    primary = groups.first

    assert_equal @shannon, primary.agent
    assert primary.primary?
    assert_equal "Submitted", primary.from_label
    assert_equal 3600, primary.seconds
  end

  # --- backward-compat: a review intent recorded BEFORE the HEAVY→PRIMARY rename
  # still says weight "heavy". The avatars treat it as "primary" (predicate + the
  # canonical display label) so old records render identically to new ones, with no
  # data migration of the append-only TaskEvent metadata. ---
  test "[unit] a legacy 'heavy' StageAgent is treated as primary and labeled 'primary'" do
    legacy  = StageAgentsHelper::StageAgent.new(weight: "heavy")
    current = StageAgentsHelper::StageAgent.new(weight: "primary")
    light   = StageAgentsHelper::StageAgent.new(weight: "light")
    none    = StageAgentsHelper::StageAgent.new(weight: nil)

    assert legacy.primary?, "the legacy 'heavy' weight is the primary (deep) seat"
    assert current.primary?, "the current 'primary' weight is the primary seat"
    refute light.primary?
    refute none.primary?

    assert_equal "primary", legacy.role_label, "a legacy 'heavy' record displays as 'primary'"
    assert_equal "primary", current.role_label
    assert_equal "light", light.role_label
    assert_nil none.role_label, "a non-review mover carries no role label"
  end

  # --- end-to-end seam: review! writes the pair to the EVENT, the avatars read it
  #
  # Regression for the reviewer→avatars seam bug: the engine records the pair on
  # the submitted→reviewed TaskEvent's metadata (NOT Task.metadata), but the
  # avatars reader pulled from task.reviewers (Task.metadata, the wrong record), so
  # the two senior avatars rendered nothing in prod. Drive the REAL write path
  # (review! → Task#stage_event_metadata via Current) through the helper so the
  # whole seam is exercised, not a hand-seeded record.
  test "review! records reviewers on the event and stage_agent_groups renders 2 seniors with primary/light" do
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
    assert_equal %w[primary light], avatars.map(&:weight)
    assert avatars.first.primary?, "the primary reviewer keeps its primary pill"
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
    # Deploy lane → the real crew ALONE; reviewed stays the pure pair.
    assert_equal %w[shannon carl], by_stage["reviewed"].map { |g| g.agent&.slug }
    assert_equal %w[avi], by_stage["assembled"].map { |g| g.agent&.slug }
    assert_equal %w[steffon], by_stage["shipped"].map { |g| g.agent&.slug }
    assert_not_equal "https://example.test/snorlax-sprite.png", by_stage["shipped"].first.avatar
    # …and the mascot never rides the deploy cards — it lives on the Build lane
    # (and, when it evolves, the Evolve reel), not beside Avi/Steffon.
    refute [by_stage["assembled"], by_stage["shipped"]].flatten.any? { |g| g.agent.is_a?(StageAgentsHelper::MascotAgent) },
           "no mascot companion rides assembled/shipped"
  end

  test "the mascot never rides the deploy cards even without an evolution" do
    # A non-evolving mascot (no Evolve reel to claim it) must still stay OFF the
    # deploy cards — the regression guard for the removed companion. Passing a live
    # mascot means the pre-change code WOULD have added it beside Avi/Steffon.
    mon = Pokemon.create!(dex: 131, name: "Lapras", slug: "lapras-deploy", generation: 1,
                          sprite_url: "https://example.test/lapras.png")
    by_stage = stage_agent_groups(deploy_task(stage: "shipped", reviewers: REVIEWERS), @agents, mascot: mon)
               .group_by(&:stage)

    assert_equal %w[avi], by_stage["assembled"].map { |g| g.agent&.slug }
    assert_equal %w[steffon], by_stage["shipped"].map { |g| g.agent&.slug }
    refute [by_stage["assembled"], by_stage["shipped"]].flatten.any? { |g| g.agent.is_a?(StageAgentsHelper::MascotAgent) }
  end

  test "stage_timeline keeps historical build mascots after a rework handoff" do
    Pokemon.create!(dex: 87, name: "Dewgong", slug: "dewgong", generation: 1,
                    sprite_url: "https://example.test/dewgong.png")
    Pokemon.create!(dex: 88, name: "Grimer", slug: "grimer", generation: 1,
                    sprite_url: "https://example.test/grimer.png")
    task = Task.create!(title: "mascot timeline handoff task", stage: "building",
                        metadata: { "devops" => { "mascot" => "grimer" } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 5.hours.ago,
                      metadata: { "mascot" => { "slug" => "dewgong", "name" => "Dewgong",
                                                 "avatar" => "https://example.test/dewgong.png" } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600,
                      metadata: { "mascot" => { "slug" => "dewgong", "name" => "Dewgong",
                                                 "avatar" => "https://example.test/dewgong.png" } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600,
                      metadata: { "mascot" => { "slug" => "dewgong", "name" => "Dewgong",
                                                 "avatar" => "https://example.test/dewgong.png" } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "blocked",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "blocked", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600,
                      metadata: { "mascot" => { "slug" => "grimer", "name" => "Grimer",
                                                 "avatar" => "https://example.test/grimer.png" } })

    blocks = stage_timeline(task.reload, @agents)

    assert_equal ["Dewgong", "Dewgong", "Dewgong", nil, "Grimer"],
                 blocks.map { |block| block.agents.first&.name }
    assert blocks.last.in_progress?, "the current rework →building span ticks live on the same card"
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

  test "crew_clusters keeps review primary-on-top and splits assembled/shipped with their own time" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS) # reviewed 3600, assembled 1800, shipped 600
    clusters = crew_clusters(task, stage_agent_groups(task, @agents))
    review = clusters.find { |c| c.lane == :review }
    assembled = clusters.find { |c| c.lane == :assembled }
    shipped = clusters.find { |c| c.lane == :shipped }

    assert review.stacked.last.primary?, "primary reviewer is on top (rendered last)"
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

  test "crew_columns reserves the fourth (deploy) lane on the assembled column, empty until shipped" do
    # The assembled column now carries the 4th (ship) lane so the card holds its width
    # and never reflows when it ships — but with no ship intent that slot stays EMPTY.
    assembled = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    cols = crew_columns(assembled, stage_agent_groups(assembled, @agents), board: :deploy)
    assert_equal %i[build review assembled shipped], cols.map(&:lane), "four fixed lanes on the assembled column"
    ship = cols.find { |c| c.lane == :shipped }
    assert_empty ship.stacked, "the reserved deploy slot is empty until a ship intent lands"
    assert_nil ship.live_since, "no live ticker on an unfilled deploy slot"

    shipped = deploy_task(stage: "shipped", reviewers: REVIEWERS)
    shipped_cols = crew_columns(shipped, stage_agent_groups(shipped, @agents), board: :deploy)
    assert_equal %i[build review assembled shipped], shipped_cols.map(&:lane)
    assert shipped_cols.find { |c| c.lane == :shipped }.stacked.any?, "a shipped task fills the deploy slot"
  end

  test "crew_columns fills the assembled card's deploy slot from an open ship intent (Avi, live)" do
    # Avi records a ship intent while the task is still assembled — his avatar + a live
    # ticker fill the reserved 4th slot, the Deploy mirror of the build-lane counter.
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    intent = task.record_intent_event(to_stage: "shipped", actor: "avi")
    cols = crew_columns(task.reload, stage_agent_groups(task, @agents), board: :deploy, agents: @agents)

    assert_equal %i[build review assembled shipped], cols.map(&:lane), "still four fixed lanes"
    ship = cols.find { |c| c.lane == :shipped }
    assert_equal %w[avi], ship.stacked.map { |a| a.agent&.slug }, "Avi's deploy intent populates the 4th slot"
    assert_equal intent.occurred_at.to_i, ship.live_since.to_i, "the deploy slot ticks live from the ship intent"
  end

  test "crew_columns is additive — rendering the deploy crew never mutates the task's mascot" do
    Pokemon.create!(dex: 70, name: "Weepinbell", slug: "weepinbell", generation: 1,
                    sprite_url: "https://example.test/weepinbell-sprite.png")
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    task.update!(metadata: { "devops" => { "mascot" => "weepinbell", "mascot_session" => "sess-x" } })
    task.record_intent_event(to_stage: "shipped", actor: "avi")
    before = task.reload.devops.deep_dup

    crew_columns(task, stage_agent_groups(task, @agents), board: :deploy, agents: @agents,
                                                          mascot: Pokemon.find_by(slug: "weepinbell"))

    assert_equal before, task.reload.devops,
                 "the existing mascot (and every devops field) survives the deploy crew render verbatim"
  end

  test "crew_columns backfills Steffon on an actor-less ship intent over an assembled task" do
    # A conductor-recorded ship intent (no actor) still surfaces a face — the ship
    # lane's canonical owner, Steffon — so the assembled card never goes faceless mid-deploy.
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    task.record_intent_event(to_stage: "shipped", actor: nil)
    ship = crew_columns(task.reload, stage_agent_groups(task, @agents), board: :deploy, agents: @agents)
           .find { |c| c.lane == :shipped }

    assert_equal %w[steffon], ship.stacked.map { |a| a.agent&.slug }, "actor-less ship intent backfills Steffon"
    assert_not_nil ship.live_since
  end

  # A blocked card reads design · building · blocker on the DEPLOY board too (not just
  # /tasks): the collapsed build lane splits back out so slots 1/2 name the design +
  # build mascots and slot 3 is the actual blocking agent — never the mascot with a ✕.
  test "crew_columns gives a blocked deploy card design · building · blocker (not the mascot)" do
    Pokemon.create!(dex: 249, name: "Lugia", slug: "lugia", generation: 2,
                    sprite_url: "https://example.test/lugia-sprite.png")
    task = blocked_journey_task(slug: "lugia", blocker: "avi")
    mon = Pokemon.find_by(slug: "lugia")

    cols = crew_columns(task, stage_agent_groups(task, @agents, mascot: mon),
                        board: :deploy, mascot: mon, agents: @agents)

    assert_equal %i[designed building blocked], cols.map(&:lane),
                 "a blocked deploy card splits the build lane back out: design · building · blocker"
    assert_equal "Lugia", cols[0].stacked.first&.name, "slot 1 is the design mascot"
    assert_equal "Lugia", cols[1].stacked.first&.name, "slot 2 is the build mascot"
    assert_equal @avi, cols[2].stacked.first&.agent, "slot 3 is the blocking agent, not the mascot"
    assert_equal 420, cols[0].seconds, "slot 1 carries the time spent designing"
    assert_equal 2160, cols[1].seconds, "slot 2 carries the time spent building"
  end

  # Component tier: the rendered blocked card fills all three slots and paints the red
  # ✕ on the blocker (last filled slot) — no dashed empty circles for a blocked card.
  test "a blocked deploy card renders three filled slots with the ✕ on the blocker" do
    Pokemon.create!(dex: 250, name: "Ho-Oh", slug: "ho-oh", generation: 2,
                    sprite_url: "https://example.test/hooh-sprite.png")
    task = blocked_journey_task(slug: "ho-oh", blocker: "avi")

    render "components/stage_agent_avatars", task: task, agents: @agents,
           variant: :stack, board: :deploy, mascot: Pokemon.find_by(slug: "ho-oh")

    assert_equal 3, rendered.scan('data-test="crew-cluster"').size, "all three slots are filled"
    assert_no_match(/data-test="crew-empty"/, rendered, "a blocked card shows no dashed empty slots")
    assert_match(/data-test="crew-blocked"/, rendered, "the blocker slot wears the red ✕")
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

  # --- the self-claim fix: only an active `building` claim ticks live -----------

  # The bug Steffon flagged: a freshly-filed `designed`/unowned task still wears its
  # mascot, and the build-step UI rendered that designed step with a green live
  # ticker — a false "someone is building this right now" intent. The mascot column
  # must still render (identity), but with NO live_since on any build step.
  test "build_step_columns gives a designed task its mascot but no live ticker" do
    mon = Pokemon.create!(dex: 50, name: "Diglett", slug: "diglett", generation: 1,
                          sprite_url: "https://example.test/diglett-sprite.png")
    designed = Task.create!(title: "freshly filed designed task", stage: "designed",
                            metadata: { "devops" => { "mascot" => "diglett" } })

    cols = crew_columns(designed.reload, stage_agent_groups(designed, @agents, mascot: mon),
                        board: :deploy, mascot: mon)

    assert_equal %i[designed building submitted], cols.map(&:lane)
    assert cols[0].stacked.any?, "the designed step still wears the mascot (identity preserved)"
    assert cols.all? { |c| c.live_since.nil? }, "an unclaimed designed task ticks NO live build counter"
  end

  # The counterpart: a real claim (`building`) still ticks the live build counter on
  # the building step — the fix must not flatten a legitimately-owned build.
  test "build_step_columns keeps the live ticker for a building-claimed task" do
    mon = Pokemon.create!(dex: 51, name: "Dugtrio", slug: "dugtrio", generation: 1,
                          sprite_url: "https://example.test/dugtrio-sprite.png")
    task = Task.create!(title: "claimed building task", stage: "building",
                        metadata: { "devops" => { "mascot" => "dugtrio" } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "carl")

    cols = crew_columns(task.reload, stage_agent_groups(task, @agents, mascot: mon),
                        board: :deploy, mascot: mon)
    building = cols.find { |c| c.lane == :building }

    assert_not_nil building.live_since, "an active `building` claim still ticks a live counter"
    assert_nil cols.find { |c| c.lane == :designed }.live_since, "the completed designed step is not live"
  end

  # The timeline mirror: a `designed`/unclaimed task surfaces NO live in-progress
  # build block (in_progress_work returns nil), while a `building` task still does.
  test "in_progress_work returns nil for a designed (unclaimed) task" do
    mascot = MascotAgent.new(name: "Diglett", avatar: "x", color: "#fff")
    designed = Task.create!(title: "designed idle timeline task", stage: "designed")
    assert_nil in_progress_work(designed.reload, @by_slug, mascot, []),
               "a filed-but-unclaimed designed task is idle — no live build block"

    building = Task.create!(title: "building live timeline task", stage: "building")
    work = in_progress_work(building.reload, @by_slug, mascot, [])
    assert_equal :build, work[:lane], "a real building claim is still live build work"
    assert_not_nil work[:live_since]
  end

  # --- stage_timeline (consolidated /tasks/:id timeline) ----------------------

  test "stage_timeline yields one block per transition with the completing crew + usage" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS)
    blocks = stage_timeline(task, @agents)

    assert_equal %w[reviewed assembled shipped], blocks.reject(&:in_progress?).map(&:to_stage),
                 "one block per completed transition, newest last"
    shipped = blocks.find { |b| b.to_stage == "shipped" }
    assert_equal %w[steffon], shipped.agents.map { |a| a.agent&.slug }
    assert_equal 600, shipped.seconds
  end

  test "stage_timeline backfills Avi/Steffon on actor-less assembled/shipped blocks" do
    task = deploy_task(stage: "shipped", reviewers: REVIEWERS, assembled_actor: nil, shipped_actor: nil)
    by_stage = stage_timeline(task, @agents).index_by(&:to_stage)

    assert_equal %w[avi], by_stage["assembled"].agents.map { |a| a.agent&.slug }
    assert_equal %w[steffon], by_stage["shipped"].agents.map { |a| a.agent&.slug }
  end

  test "stage_timeline appends a live in-progress block for an open review intent" do
    task = Task.create!(title: "timeline live review task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    live = stage_timeline(task.reload, @agents).find(&:in_progress?)

    assert_not_nil live, "an open review intent surfaces as a live block"
    assert_equal "reviewed", live.to_stage
    assert_not_nil live.live_since
    assert_equal %w[shannon carl], live.agents.map { |a| a.agent&.slug }
    assert_equal %w[primary light], live.agents.map(&:weight)
  end

  test "stage_timeline's live assembled card reads Assembled -> Shipped owned by Steffon" do
    # The standard QA window: the member is already `assembled`, so prepare records
    # Avi's QA intent toward `shipped` (qa:true), RE-HOMED to the assembled LANE
    # for the board. The timeline must NOT echo that re-homed lane as the badge
    # target (the old nonsensical "Assembled -> Assembled" no-op) — it frames the
    # live work as the real transition it rides toward, →shipped, owned by the ship
    # owner Steffon (operator decision: the timeline diverges from the board here).
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    task.record_intent_event(to_stage: "shipped", actor: "avi", qa: true)
    live = stage_timeline(task.reload, @agents).find(&:in_progress?)

    assert_not_nil live, "an open QA intent surfaces as a live block"
    assert_equal "assembled", live.from_stage
    assert_equal "Assembling", live.from_label, "a live card shows the ACTIVE (gerund) stage form"
    assert_equal "shipped", live.to_stage, "badge reads toward the REAL next stage, not the re-homed lane"
    assert_equal "Shipped", live.to_label
    assert_equal %w[steffon], live.agents.map { |a| a.agent&.slug }, "the ship owner (Steffon) heads the live ship card"
    assert_not_nil live.live_since
  end

  test "stage_timeline's live assembled card stays Steffon once his own ship intent is open" do
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    task.record_intent_event(to_stage: "shipped", actor: "avi", qa: true)     # QA first
    task.record_intent_event(to_stage: "shipped", actor: "steffon")           # ship starts later
    live = stage_timeline(task.reload, @agents).find(&:in_progress?)

    assert_equal "shipped", live.to_stage
    assert_equal %w[steffon], live.agents.map { |a| a.agent&.slug }
  end

  test "stage_timeline merges live building into the existing designed to building card" do
    mon = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1,
                          sprite_url: "https://example.test/snorlax-sprite.png")
    task = Task.create!(title: "timeline live building task", stage: "designed")
    task.build!
    blocks = stage_timeline(task.reload, @agents, mascot: mon)
    live = blocks.find(&:in_progress?)

    assert_not_nil live, "an active building claim surfaces as a live block"
    assert_equal 1, blocks.count(&:in_progress?), "there is only one live card"
    assert_equal "designed", live.from_stage
    assert_equal "building", live.to_stage, "the existing Designed → Building span becomes live"
    assert_equal "Building", live.to_label
    assert live.event, "live building reuses the transition event instead of appending a blank card"
    assert_equal "Snorlax", live.agents.first.name, "the mascot heads the live build card"
  end

  test "stage_timeline keeps genesis usage empty and accounts design work on the building transition" do
    mon = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax-usage", generation: 1)
    task = Task.create!(title: "timeline design accounting task", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 20.minutes.ago)
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 10.minutes.ago, seconds_in_from: 600, actor: "carl",
                      model: "gpt-5", tokens_in: 1200, tokens_out: 300, cost: "0.0400")

    by_stage = stage_timeline(task.reload, @agents, mascot: mon).index_by(&:to_stage)
    genesis = by_stage["designed"]
    building = by_stage["building"]

    refute genesis.usage?, "Created → Designed is the deterministic creation marker"
    assert building.usage?, "design accounting lands on the Designed → Building transition"
    assert_equal "gpt-5", building.model
    assert_equal 1500, building.tokens
    assert_equal "0.04".to_d, building.cost
    assert building.in_progress?, "the building-start transition also carries live build state"
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

  test "in_progress_work surfaces the marked QA intent (toward shipped) as live ASSEMBLED work" do
    # The standard flow: the member is already `assembled`, so the QA intent rides
    # toward `shipped` with the `qa` marker — it must render in the assembled lane,
    # NOT the ship lane (that would read as Steffon shipping).
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    task.record_intent_event(to_stage: "shipped", actor: "steffon", qa: true)
    work = in_progress_work(task.reload, @by_slug, nil, task.task_events.select(&:intent?))

    assert_equal :assembled, work[:lane], "a marked QA intent renders in the assembled lane"
    assert_equal %w[steffon], work[:agents].map { |a| a.agent&.slug }
    assert_not_nil work[:live_since]
  end

  test "in_progress_work — an open ship intent (Avi) outranks the QA intent" do
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    task.record_intent_event(to_stage: "shipped", actor: "steffon", qa: true) # QA first
    task.record_intent_event(to_stage: "shipped", actor: "avi")               # ship starts later
    work = in_progress_work(task.reload, @by_slug, nil, task.task_events.select(&:intent?))

    assert_equal :shipped, work[:lane], "once Avi is actively shipping the ship lane wins"
    assert_equal %w[avi], work[:agents].map { |a| a.agent&.slug }
  end

  test "crew_columns marks the assembled column LIVE from an open QA intent (Avi)" do
    # The reviewer's board assertion: an already-assembled member whose QA intent is
    # open shows the assembled cluster ticking — Avi QA-ing — keeping his avatar.
    task = deploy_task(stage: "assembled", reviewers: REVIEWERS)
    task.record_intent_event(to_stage: "shipped", actor: "avi", qa: true)
    cols = crew_columns(task.reload, stage_agent_groups(task, @agents), board: :deploy, agents: @agents)

    assembled = cols.find { |c| c.lane == :assembled }
    assert_equal %w[avi], assembled.stacked.map { |a| a.agent&.slug }, "Avi still owns the assembled column"
    assert_not_nil assembled.live_since, "and it now ticks LIVE — QA in progress"
    assert_empty cols.find { |c| c.lane == :shipped }.stacked, "ship slot stays empty while only QA is live"
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

  test "crew_columns lets a new review intent override an old completed review badge" do
    task = Task.create!(title: "board rework review task", stage: "submitted")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 3.hours.ago, seconds_in_from: 1800, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 2.hours.ago, seconds_in_from: 21.minutes,
                      metadata: { "reviewers" => REVIEWERS })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "blocked",
                      occurred_at: 90.minutes.ago, seconds_in_from: 30.minutes)
    TaskEvent.create!(task_slug: task.slug, from_stage: "blocked", to_stage: "building",
                      occurred_at: 45.minutes.ago, seconds_in_from: 45.minutes)
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 10.minutes.ago, seconds_in_from: 35.minutes, actor: "carl")
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)

    review = crew_columns(task.reload, stage_agent_groups(task, @agents), board: :deploy, agents: @agents)
             .find { |c| c.lane == :review }

    assert_equal intent.occurred_at.to_i, review.live_since.to_i,
                 "the active re-review must tick instead of showing the old static review duration"
    assert_equal %w[shannon carl], review.stacked.map { |a| a.agent&.slug },
                 "the active review pair owns the review lane"
  end

  test "crew_columns ignores a stale review intent after direct rework block" do
    task = Task.create!(title: "board direct block task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    task.block!
    task.build!
    task.submit!

    review = crew_columns(task.reload, stage_agent_groups(task, @agents), board: :deploy, agents: @agents)
             .find { |c| c.lane == :review }

    assert_empty review.stacked, "the old review pair must not still own the review lane"
    assert_nil review.live_since, "the old review start must not keep ticking after resubmit"
  end

  test "crew_columns without an agent map skips the live injection (legacy callers unchanged)" do
    task = Task.create!(title: "board no-agents task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    task.reload

    review = crew_columns(task, stage_agent_groups(task, @agents), board: :deploy).find { |c| c.lane == :review }
    assert_empty review.stacked, "no agents passed → no live cluster, exactly as before"
  end

  # --- stage_crew_renderable? (a fresh designed card shows its mascot) ----------

  test "stage_crew_renderable? shows the build-lane mascot even with no crew entries" do
    mascot = Pokemon.new(slug: "dugtrio")
    designed = Task.new(stage: "designed")

    # The fix: a fresh designed/building task (empty crew entries) still shows its
    # mascot on the board card, on either board.
    assert stage_crew_renderable?(designed, [], mascot: mascot, variant: :stack, board: :build)
    assert stage_crew_renderable?(designed, [], mascot: mascot, variant: :stack, board: :deploy)
    assert stage_crew_renderable?(Task.new(stage: "building"), [], mascot: mascot, variant: :stack, board: :deploy)

    # No mascot → nothing to paint, exactly as before.
    assert_not stage_crew_renderable?(designed, [], mascot: nil, variant: :stack, board: :build)
    # The detail panel still requires real crew entries.
    assert_not stage_crew_renderable?(designed, [], mascot: mascot, variant: :detailed, board: :build)
    # A deploy-stage card with no entries shows nothing even with a mascot (no build steps).
    assert_not stage_crew_renderable?(Task.new(stage: "reviewed"), [], mascot: mascot, variant: :stack, board: :deploy)
    # Real entries always render.
    assert stage_crew_renderable?(designed, [Object.new], mascot: nil, variant: :stack, board: :deploy)
  end

  test "build_step_board? matches when the build steps (and mascot) are painted" do
    assert build_step_board?(Task.new(stage: "designed"), :deploy)
    assert build_step_board?(Task.new(stage: "building"), :deploy)
    assert build_step_board?(Task.new(stage: "submitted"), :build), "build board keeps the split through submitted"
    assert_not build_step_board?(Task.new(stage: "submitted"), :deploy)
    assert_not build_step_board?(Task.new(stage: "reviewed"), :deploy)
    assert build_step_board?(Task.new(stage: "blocked"), :build), "build board keeps blocked cards in the three-slot rhythm"
  end

  # Component tier: the single MascotAgent construction point is shiny-aware —
  # a shiny task wears the shiny sprite, everything else keeps the normal one.
  test "task_mascot_face wears the shiny sprite only for a shiny draw" do
    pokemon = Pokemon.create!(dex: 302, name: "Lapras", slug: "lapras", generation: 1,
                              sprite_url: "normal-sprite.png", shiny_sprite_url: "shiny-sprite.png")
    shiny_task = Task.new(metadata: { "devops" => { "mascot_shiny" => true } })
    plain_task = Task.new(metadata: {})

    assert_equal "shiny-sprite.png", task_mascot_face(shiny_task, pokemon).avatar
    assert_equal "normal-sprite.png", task_mascot_face(plain_task, pokemon).avatar
    assert_equal pokemon.name, task_mascot_face(shiny_task, pokemon).name
    assert_nil task_mascot_face(plain_task, nil)
  end

  # --- final evolution: the Evolve card + the first-crew reveal ----------------

  # A full designed→…→reviewed(/shipped) journey whose mascot evolves at the two
  # gates — base → first-evo at submitted, → final form at reviewed — so a final
  # evolution surfaces. Snapshots are baked directly for control over each
  # form (the gate mechanics themselves live in TaskMascotEvolutionTest).
  # Known dexes so the seed is collision-proof against shared-DB leftovers.
  FORM_DEX = { "charmander" => 4, "charmeleon" => 5, "charizard" => 6, "diglett" => 50, "dugtrio" => 51 }.freeze

  def evolving_journey(stage:, base: "charmander", first: "charmeleon", third: "charizard")
    # Seed the real line so final_evolution can check whether the reviewed snapshot
    # is terminal. Idempotent (first_or_initialize).
    { base => base, first => base, third => base }.each do |slug, base_slug|
      evolution = if slug == base && first != base
                    [first]
                  elsif slug == base && third != base
                    [third]
                  elsif slug == first && third != first
                    [third]
                  else
                    []
                  end
      Pokemon.where(slug: slug).first_or_initialize
             .update!(dex: FORM_DEX.fetch(slug), name: slug.capitalize, slug: slug,
                      generation: 1, base: base_slug, evolution: evolution, baby: [])
    end
    task = Task.create!(title: "evolving #{base} #{stage} task")
    task.task_events.delete_all
    snap = ->(slug) { { "mascot" => { "slug" => slug, "name" => slug.capitalize, "avatar" => "https://example.test/#{slug}.png" } } }
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 6.hours.ago, actor: "carl", metadata: snap[base])
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 5.hours.ago, seconds_in_from: 3600, actor: "carl", metadata: snap[base])
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600, actor: "carl", metadata: snap[first])
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600, metadata: snap[third].merge("reviewers" => REVIEWERS))
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon", metadata: snap[third])
    if stage == "shipped"
      TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                        occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi", metadata: snap[third])
    end
    task.update_columns(stage: stage)
    task.reload
  end

  test "final_evolution detects the new form produced at the reviewed gate" do
    evo = final_evolution(evolving_journey(stage: "assembled"))

    assert_not_nil evo
    assert_equal "charmeleon", evo.from["slug"]
    assert_equal "charizard", evo.to["slug"]
    assert_equal "Charizard", evo.to_face.name
    assert_equal "https://example.test/charizard.png", evo.to_face.avatar
  end

  test "final_evolution detects a 2-stage line that waits until reviewed" do
    journey = evolving_journey(stage: "assembled", base: "diglett", first: "diglett", third: "dugtrio")
    evo = final_evolution(journey)

    assert_not_nil evo
    assert_equal "diglett", evo.from["slug"]
    assert_equal "dugtrio", evo.to["slug"]
  end

  test "final_evolution is nil before the task is reviewed" do
    assert_nil final_evolution(deploy_task(stage: "submitted", reviewers: REVIEWERS))
  end

  test "final_evolution reads the real submit + review evolution end to end" do
    [[4, "charmander", ["charmeleon"]], [5, "charmeleon", ["charizard"]], [6, "charizard", []]].each do |dex, slug, evo|
      Pokemon.where(slug: slug).first_or_initialize
             .update!(dex: dex, name: slug.capitalize, slug: slug, generation: 1, base: "charmander", evolution: evo, baby: [])
    end
    task = Task.create!(title: "real evolution path task")
    task.update_columns(stage: "building",
                        metadata: { "devops" => { "mascot" => "charmander", "session_id" => "s1", "mascot_session" => "s1" } })
    task.reload.submit!
    task.review!

    evo = final_evolution(task.reload)
    assert_not_nil evo, "charmeleon → charizard at the reviewed gate is a final evolution"
    assert_equal "charmeleon", evo.from["slug"]
    assert_equal "charizard", evo.to["slug"]
  end

  test "final_evolution is nil when review does a non-final first evolution" do
    # A task that reaches reviewed WITHOUT passing the submit gate evolves base →
    # first form AT the review gate (Charmander → Charmeleon). That is not final,
    # so it must NOT get an Evolve card.
    %w[charmander charmeleon].each_with_index do |slug, i|
      Pokemon.where(slug: slug).first_or_initialize
             .update!(dex: 4 + i, name: slug.capitalize, slug: slug, generation: 1,
                      base: "charmander", evolution: (i.zero? ? ["charmeleon"] : ["charizard"]), baby: [])
    end
    task = Task.create!(title: "skipped submit assemble task")
    task.task_events.delete_all
    snap = ->(slug) { { "mascot" => { "slug" => slug, "name" => slug.capitalize, "avatar" => "https://example.test/#{slug}.png" } } }
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 3.hours.ago, actor: "carl", metadata: snap["charmander"])
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600, actor: "carl", metadata: snap["charmander"])
    # straight to reviewed — the submit gate was skipped, so this is the FIRST evolution
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "reviewed",
                      occurred_at: 1.hour.ago, seconds_in_from: 1800,
                      metadata: snap["charmeleon"].merge("reviewers" => REVIEWERS))
    task.update_columns(stage: "reviewed")

    assert_nil final_evolution(task.reload),
               "a first evolution at a skipped-submit review is not a final evolution"
  end

  test "stage_timeline splices an Evolve card after review and strips later companions" do
    blocks = stage_timeline(evolving_journey(stage: "shipped"), @agents)

    assert_equal %w[designed building submitted reviewed evolve assembled shipped],
                 blocks.map { |b| b.evolution? ? "evolve" : b.to_stage },
                 "the Evolve card sits right after Submitted → Reviewed"

    assembled = blocks.find { |b| b.to_stage == "assembled" && !b.evolution? }
    assert_equal %w[steffon], assembled.agents.map { |a| a.agent&.slug },
                 "Reviewed → Assembled is Steffon alone — the final mascot moved to the Evolve card"
    refute assembled.agents.any? { |a| a.agent.is_a?(StageAgentsHelper::MascotAgent) }

    shipped = blocks.find { |b| b.to_stage == "shipped" }
    assert_equal %w[avi], shipped.agents.map { |a| a.agent&.slug },
                 "Assembled → Shipped is Avi alone too — the reel is the only reveal of the evolved form"
    refute shipped.agents.any? { |a| a.agent.is_a?(StageAgentsHelper::MascotAgent) }

    evolve = blocks.find(&:evolution?)
    assert_equal "Charmeleon", evolve.evolution.from.name
    assert_equal "Charizard", evolve.evolution.to.name
    assert_equal @shannon, evolve.evolution.trigger.agent, "the primary reviewer triggered the evolution"
  end

  test "stage_timeline celebrates a 2-stage final evolution at review" do
    blocks = stage_timeline(evolving_journey(stage: "assembled", base: "diglett", first: "diglett", third: "dugtrio"), @agents)

    assert blocks.any?(&:evolution?), "a 2-stage line earns its final Evolve card at review"
    assembled = blocks.find { |b| b.to_stage == "assembled" }
    refute assembled.agents.any? { |a| a.agent.is_a?(StageAgentsHelper::MascotAgent) },
           "the final mascot belongs to the Evolve card, not the assembled card"
  end

  test "crew_columns stacks the evolved final form on the build crew and clears the deploy companion" do
    task = evolving_journey(stage: "shipped")
    cols = crew_columns(task, stage_agent_groups(task, @agents), board: :deploy)
    build = cols.find { |c| c.lane == :build }
    assembled = cols.find { |c| c.lane == :assembled }
    shipped = cols.find { |c| c.lane == :shipped }

    assert_equal "Charizard", build.stacked.last.name, "the evolved final form joins the FIRST (build) crew"
    assert build.stacked.any? { |a| a.name == "Charmeleon" }, "the first-evo form stays on the build crew"
    assert_equal %w[steffon], assembled.stacked.map { |a| a.agent&.slug }
    refute assembled.stacked.any? { |a| a.agent.is_a?(StageAgentsHelper::MascotAgent) }, "no mascot companion beside Steffon"
    assert_equal %w[avi], shipped.stacked.map { |a| a.agent&.slug }
    refute shipped.stacked.any? { |a| a.agent.is_a?(StageAgentsHelper::MascotAgent) }, "no mascot companion beside Avi"
  end

  test "crew_columns stacks a 2-stage final form and clears the deploy companion" do
    task = evolving_journey(stage: "shipped", base: "diglett", first: "diglett", third: "dugtrio")
    cols = crew_columns(task, stage_agent_groups(task, @agents), board: :deploy)
    build = cols.find { |c| c.lane == :build }
    assembled = cols.find { |c| c.lane == :assembled }

    assert_equal "Dugtrio", build.stacked.last.name
    refute assembled.stacked.any? { |a| a.agent.is_a?(StageAgentsHelper::MascotAgent) },
           "the companion leaves the assembled cluster when the final form has its own reveal"
  end
end
