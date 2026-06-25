require "test_helper"

class ReleaseTest < ActiveSupport::TestCase
  def reviewed_task(label = "default")
    Task.create!(title: "reviewable #{label} demo task", stage: "reviewed")
  end

  test "open! creates an assembling release with a generated slug" do
    rel = Release.open!
    assert_equal "assembling", rel.state
    assert rel.slug.start_with?("rel-"), rel.slug
    assert rel.active?
  end

  test "open! defaults the integration branch to the persistent `release`" do
    assert_equal "release", Release::BRANCH
    assert_equal "release", Release.open!.branch
  end

  test "current_or_open! returns the active release, else opens one" do
    opened = Release.current_or_open!
    assert_equal "assembling", opened.state
    assert_equal opened, Release.current_or_open!, "returns the SAME active release, doesn't open a second"
    assert_equal 1, Release.count
  end

  test "only one active release at a time (singleton)" do
    Release.open!
    assert_raises(ActiveRecord::RecordInvalid) { Release.open! }
  end

  test "a shipped release frees the singleton for a new one" do
    Release.open!.ship!
    assert_nothing_raised { Release.open! }
  end

  test "an abandoned release frees the singleton too" do
    Release.open!.abandon!
    assert_nothing_raised { Release.open! }
  end

  test "Release.current returns the active release" do
    rel = Release.open!
    assert_equal rel, Release.current
    rel.ship!
    assert_nil Release.current
  end

  test "add attaches a reviewed task and marks it assembled" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)
    assert_equal rel.slug, task.reload.release_slug
    assert_equal "assembled", task.stage
  end

  test "add from an assembled RC auto-reopens, then adds (a late merge re-QAs)" do
    rel = Release.open!
    rel.assemble!
    assert_equal "assembled", rel.state

    late = reviewed_task
    rel.add(late)

    assert_equal "assembling", rel.reload.state, "a late merge reopens the candidate"
    assert_equal "assembled", late.reload.stage, "the late member must flip to assembled, not stay reviewed"
    assert_equal 1, rel.tasks.count
  end

  test "add onto an assembled RC is atomic — a failed member flip rolls back the reopen" do
    rel = Release.open!
    rel.assemble!
    task = reviewed_task
    # Blow up the member flip AFTER reopen! would have run, so a non-atomic `add`
    # leaves the RC reopened (assembling) with the member never attached.
    def task.update!(*); raise "boom"; end

    assert_raises(RuntimeError) { rel.add(task) }
    assert_equal "assembled", rel.reload.state,
                 "the reopen must roll back when the member flip fails — no half-reopened RC"
  end

  test "add still refuses from a terminal release" do
    rel = Release.open!
    rel.ship!
    assert_raises(ArgumentError) { rel.add(reviewed_task) }
  end

  test "assemble! marks the release assembled and stamps the time" do
    rel = Release.open!
    rel.assemble!
    assert_equal "assembled", rel.state
    assert_not_nil rel.assembled_at
  end

  test "ship! flips members to shipped, records who, stamps shipped_at" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)
    rel.assemble!

    rel.ship!(by: "alex")

    assert_equal "shipped", rel.reload.state
    assert_equal "alex", rel.confirmed_by
    assert_not_nil rel.shipped_at
    assert_not_nil rel.confirmed_at
    assert_equal "shipped", task.reload.stage
    assert_not_nil task.completed_at # Task#ship! callback ran (not update_all)
  end

  test "abandon! returns members to reviewed and clears the release link" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)

    rel.abandon!

    assert_equal "abandoned", rel.reload.state
    assert_equal "reviewed", task.reload.stage
    assert_nil task.release_slug
  end

  test "state must be one of the known states" do
    assert_not Release.new(state: "bogus").valid?
  end

  test "tasks association reads members by release_slug" do
    rel = Release.open!
    a = reviewed_task("A")
    b = reviewed_task("B")
    rel.add(a)
    rel.add(b)
    assert_equal 2, rel.tasks.count
    assert_equal rel, a.reload.release
  end

  # --- reopen! (additive prepare: absorb new work into an assembled RC) ---

  test "reopen! pulls an assembled release back to assembling" do
    rel = Release.open!
    rel.assemble!
    rel.reopen!
    assert_equal "assembling", rel.reload.state
  end

  test "reopen! only works from assembled" do
    rel = Release.open! # assembling
    assert_raises(ArgumentError) { rel.reopen! }
    rel.assemble!
    rel.ship!
    assert_raises(ArgumentError) { rel.reopen! } # terminal
  end

  test "reopen! lets a new reviewed task join an already-assembled RC" do
    rel = Release.open!
    rel.add(reviewed_task("first"))
    rel.assemble!

    rel.reopen!
    rel.add(reviewed_task("second"))
    rel.assemble!

    assert_equal 2, rel.tasks.count
    assert_equal "assembled", rel.reload.state
  end

  # --- transition guards (a terminal release must stay terminal) ---

  test "a terminal release cannot be revived" do
    rel = Release.open!
    rel.ship!
    assert_raises(ArgumentError) { rel.assemble! }
    assert_raises(ArgumentError) { rel.ship! }
    assert_raises(ArgumentError) { rel.abandon! }
  end

  test "assemble! only transitions from assembling" do
    rel = Release.open!
    rel.assemble!
    assert_raises(ArgumentError) { rel.assemble! } # already assembled
  end

  test "add rejects a task that is not reviewed" do
    rel = Release.open!
    designed = Task.create!(title: "Not reviewed yet") # stage: designed
    assert_raises(ArgumentError) { rel.add(designed) }
  end

  # --- last_shipped (the board's "Last Release" section) ---

  test "last_shipped returns the most recently shipped, ignoring active releases" do
    older = Release.open!
    older.ship!
    older.update_column(:shipped_at, 2.days.ago)

    newer = Release.open!
    newer.ship!
    newer.update_column(:shipped_at, 1.hour.ago)

    active = Release.open! # assembling — not shipped

    assert_equal newer, Release.last_shipped, "returns the most-recent shipped release"
    assert_not_equal active, Release.last_shipped, "never returns an active release"
  end

  test "last_shipped is nil when nothing has shipped" do
    Release.open! # assembling only
    assert_nil Release.last_shipped
  end

  test "current is nil when no active release exists" do
    assert_nil Release.current, "nil with no releases at all"
    Release.open!.ship!
    assert_nil Release.current, "a shipped release is not current"
  end

  # --- per-step test-tier ownership (devops-cycle-design §1.2) ---

  test "the tier→step map matches the redesign: base@review, integration+e2e-smoke@prepare, full-e2e@ship" do
    assert_equal %w[base], Release.test_tiers_for("review")
    assert_equal %w[integration e2e-smoke], Release.test_tiers_for("prepare")
    assert_equal %w[e2e-full], Release.test_tiers_for("ship")
    assert_equal [], Release.test_tiers_for("nope"), "an unknown step owns no tiers"
  end

  test "each test tier is owned by exactly one step — so no step re-runs a lower tier" do
    all = Release::STEP_TEST_TIERS.values.flatten
    assert_equal all.uniq.sort, all.sort, "a tier owned by two steps would re-run; ownership must be disjoint"

    assert_equal "review", Release.step_owning_tier("base")
    assert_equal "prepare", Release.step_owning_tier("e2e-smoke")
    assert_equal "prepare", Release.step_owning_tier("integration")
    assert_equal "ship", Release.step_owning_tier("e2e-full")
    assert_nil Release.step_owning_tier("base-not-real")
  end

  # --- conductor mascot (the agent working this deployment) -------------------

  def seed_pokemon
    %w[bulbasaur charmander squirtle pikachu snorlax dragonite].each_with_index.map do |slug, i|
      Pokemon.create!(dex: 300 + i, name: slug.capitalize, slug: slug, types: %w[normal], generation: 1)
    end
  end

  test "devops/devops_field/mascot are safe on a fresh, unstamped release" do
    rel = Release.open!
    assert_equal({}, rel.devops, "no devops metadata yet → empty hash, never nil")
    assert_nil rel.devops_field("mascot")
    assert_nil rel.mascot, "no mascot stamped → nil so the card degrades gracefully"
  end

  test "stamp_conductor_mascot! stamps the session's mascot into devops metadata" do
    seed_pokemon
    rel = Release.open!
    rel.stamp_conductor_mascot!("sess-1")

    expected = SessionMascot.for("sess-1").mascot_slug
    assert_equal expected, rel.reload.devops_field("mascot"), "stamps the SESSION's mascot slug"
    assert_equal "sess-1", rel.devops_field("mascot_session"), "records the owning session"
    assert_equal expected, rel.mascot.slug, "#mascot resolves the stamped Pokémon"
  end

  test "stamp_conductor_mascot! is idempotent for the same session (never re-rolls)" do
    seed_pokemon
    rel = Release.open!
    first = rel.stamp_conductor_mascot!("sess-1").devops_field("mascot")
    rel.stamp_conductor_mascot!("sess-1")

    assert_equal first, rel.reload.devops_field("mascot"), "same session keeps the same face"
  end

  test "stamp_conductor_mascot! swaps the mascot on a handoff (different session)" do
    seed_pokemon
    rel = Release.open!
    rel.stamp_conductor_mascot!("sess-a")
    before = rel.devops_field("mascot")

    rel.stamp_conductor_mascot!("sess-b")

    assert_equal "sess-b", rel.reload.devops_field("mascot_session"), "the new session takes ownership"
    refute_equal before, rel.devops_field("mascot"), "two sessions never share a Pokémon → the face swaps"
    assert_equal SessionMascot.for("sess-b").mascot_slug, rel.mascot.slug
  end

  test "stamp_conductor_mascot! is a no-op for a blank session" do
    seed_pokemon
    rel = Release.open!
    rel.stamp_conductor_mascot!("")
    rel.stamp_conductor_mascot!(nil)
    assert_nil rel.reload.devops_field("mascot")
  end
end
