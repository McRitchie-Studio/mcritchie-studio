require "test_helper"
require "minitest/mock"

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

  test "add attaches (sweeps) a reviewed task without moving its stage" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)
    assert_equal rel.slug, task.reload.release_slug
    assert_equal "reviewed", task.stage, "the assembled flip waits for QA-green (Conductor.qa_green!)"
    assert_equal Task::MERGED_RELEASE, task.merged
  end

  test "add attaches an assembled straggler without moving it" do
    rel = Release.open!
    straggler = Task.create!(title: "straggler assembled leftover task", stage: "assembled")
    rel.add(straggler)
    assert_equal rel.slug, straggler.reload.release_slug
    assert_equal "assembled", straggler.stage
    assert_equal Task::MERGED_RELEASE, straggler.merged
  end

  test "[unit] add never downgrades a merged:main straggler back to release (cross-release re-adopt)" do
    # The interrupted-ship half-state: the prior cycle's ff stamped merged:"main"
    # but the member never flipped `shipped`. When a LATER release re-adopts it,
    # sweep!'s never-regress short-circuit can't see it (it only covers
    # CURRENT-release members) — add itself must refuse the downgrade.
    prior = Release.open!
    straggler = Task.create!(title: "interrupted ship straggler task", stage: "assembled",
                             release_slug: prior.slug, merged: Task::MERGED_MAIN)
    prior.update!(state: "shipped") # the prior cycle closed without flipping it

    rel = Release.open!
    rel.add(straggler)

    assert_equal rel.slug, straggler.reload.release_slug, "the straggler re-rides the new RC"
    assert_equal Task::MERGED_MAIN, straggler.merged,
                 "its code is already ff'd onto main — add must not re-stamp merged:release"
  end

  test "add from an assembled RC auto-reopens, then adds (a late merge re-QAs)" do
    rel = Release.open!
    rel.assemble!
    assert_equal "assembled", rel.state

    late = reviewed_task
    rel.add(late)

    assert_equal "assembling", rel.reload.state, "a late sweep reopens the candidate"
    assert_equal "reviewed", late.reload.stage, "the late member waits for the next QA-green flip"
    assert_equal Task::MERGED_RELEASE, late.merged
    assert_equal 1, rel.tasks.count
  end

  test "add onto an assembled RC is atomic — a failed member flip rolls back the reopen" do
    rel = Release.open!
    rel.assemble!
    task = reviewed_task
    # Blow up the member attach AFTER reopen! would have run, so a non-atomic
    # `add` leaves the RC reopened (assembling) with the member never attached.
    def task.update!(*); raise "boom"; end

    assert_raises(RuntimeError) { rel.add(task) }
    assert_equal "assembled", rel.reload.state,
                 "the reopen must roll back when the member attach fails — no half-reopened RC"
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

  test "[unit] ship! broadcasts the release as shipped before member task flips" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)
    rel.assemble!

    events = []
    DeploymentsBroadcaster.stub(:release_modules, -> { events << "release" }) do
      DeploymentsBroadcaster.stub(:task_event, ->(event) { events << "task:#{event.to_stage}" }) do
        rel.ship!(by: "avi")
      end
    end

    assert_equal "release", events.first
    assert_includes events, "task:shipped"
  end

  test "[unit] ship! pauses between member flips when a cadence is provided" do
    rel = Release.open!
    older = Task.create!(title: "older cadence release member", stage: "reviewed", created_at: 20.minutes.ago)
    newer = Task.create!(title: "newer cadence release member", stage: "reviewed", created_at: 5.minutes.ago)
    rel.add(older)
    rel.add(newer)
    rel.assemble!

    pauses = []
    rel.stub(:pause_between_member_shipments, ->(seconds) { pauses << seconds }) do
      rel.ship!(member_pause: 1)
    end

    assert_equal [1.0], pauses
    assert_equal %w[shipped shipped], [older.reload.stage, newer.reload.stage]
  end

  test "[unit] ship! ranks newer members above older members" do
    rel = Release.open!
    older = Task.create!(title: "older rank release member", stage: "reviewed", created_at: 20.minutes.ago)
    newer = Task.create!(title: "newer rank release member", stage: "reviewed", created_at: 5.minutes.ago)
    rel.add(older)
    rel.add(newer)
    rel.assemble!

    rel.association(:tasks).target = [newer.reload, older.reload]
    rel.association(:tasks).loaded!
    rel.ship!

    assert_operator newer.reload.position, :>, older.reload.position,
                    "newer release members should receive the fresher board rank"
  end

  test "abandon! returns members to reviewed and clears the release link" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)

    rel.abandon!

    assert_equal "abandoned", rel.reload.state
    assert_equal "reviewed", task.reload.stage
    assert_nil task.release_slug
    assert_equal Task::MERGED_RELEASE, task.merged,
                 "merged stays — un-reverted code still rides `release`, so the next sweep skips re-merging"
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

  test "add rejects a task that is not sweepable (neither reviewed nor assembled)" do
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

  # --- production smoke seal --------------------------------------------------

  test "[unit] a fresh release is unsealed (smoke_seal nil, not smoke_sealed?)" do
    rel = Release.open!
    assert_nil rel.smoke_seal
    assert_not rel.smoke_sealed?
  end

  test "[unit] record_smoke_seal! persists the verdict + rehydrates it as a value object" do
    rel = Release.open!
    rel.record_smoke_seal!(Release::SmokeSeal.from_result(passed: true, summary: "green vs prod"))

    seal = rel.reload.smoke_seal
    assert_instance_of Release::SmokeSeal, seal
    assert seal.green?
    assert_equal "green vs prod", seal.summary
    assert seal.checked_at.present?
    assert rel.smoke_sealed?
  end

  test "[unit] record_smoke_seal! stores a red verdict too" do
    rel = Release.open!
    rel.record_smoke_seal!(Release::SmokeSeal.from_result(passed: false, summary: "down"))
    assert rel.reload.smoke_seal.red?
  end

  test "[unit] the seal persists across the ship flip" do
    rel = Release.open!
    rel.record_smoke_seal!(Release::SmokeSeal.from_result(passed: true))
    rel.ship!
    assert rel.reload.smoke_seal.green?, "ship! never clobbers the recorded seal"
  end

  test "[unit] recording the seal re-renders the live board (after_commit broadcast)" do
    rel = Release.open!
    calls = 0
    DeploymentsBroadcaster.stub(:release_modules, -> { calls += 1 }) do
      rel.record_smoke_seal!(Release::SmokeSeal.from_result(passed: true))
    end
    assert_operator calls, :>=, 1, "the seal write broadcasts the deployments modules"
  end

  # --- merged: stamped at the release git-operation boundaries ---

  test "[integration] add stamps the member merged=release when its PR joins the RC" do
    rel = Release.open!
    task = reviewed_task("merged-release")
    rel.add(task)
    assert_equal "reviewed", task.reload.stage, "the sweep never moves the stage"
    assert_equal Task::MERGED_RELEASE, task.merged
  end

  test "[integration] ship! stamps every member merged=main" do
    rel = Release.open!
    task = reviewed_task("merged-main")
    rel.add(task)
    rel.ship!
    assert_equal "shipped", task.reload.stage
    assert_equal Task::MERGED_MAIN, task.merged
  end

  # --- stage timeline ----------------------------------------------------------

  test "[unit] a fresh release has an untouched stage timeline" do
    rel = Release.open!
    assert_nil rel.current_stage
    assert_nil rel.current_stage_index
    Release::STAGE_NAMES.each { |stage| assert_not rel.stage_reached?(stage), "#{stage} must be unreached" }
    assert_equal Release::STAGE_NAMES, rel.stage_stamps.keys
    assert rel.stage_stamps.values.all?(&:nil?)
  end

  test "[unit] stamp_stage! is a first-write-wins time-and-boolean" do
    rel = Release.open!
    first = 2.hours.ago.change(usec: 0)
    rel.stamp_stage!("qa_deploying", at: first)
    assert_equal first, rel.stage_stamp("qa_deploying")
    assert rel.stage_reached?("qa_deploying")

    rel.stamp_stage!("qa_deploying", at: Time.current)
    assert_equal first, rel.reload.stage_stamp("qa_deploying"), "a stamped stage is immutable"
  end

  test "[unit] stage_stamp/stamp_stage!/stage_reached? reject unknown stages" do
    rel = Release.open!
    assert_raises(ArgumentError) { rel.stage_stamp("warp") }
    assert_raises(ArgumentError) { rel.stamp_stage!("warp") }
    assert_raises(ArgumentError) { rel.stage_reached?("warp") }
  end

  test "[unit] stage_started_at_or_before returns the stage's own start stamp when present" do
    rel = Release.open!
    stamp = Time.zone.parse("2026-06-29 12:00:00")
    rel.stamp_stage!("qa_deploying", at: stamp)
    assert_equal stamp, rel.stage_started_at_or_before("qa_deploying")
  end

  test "[unit] stage_started_at_or_before falls back to the nearest EARLIER stamp, then release-open" do
    created = Time.zone.parse("2026-06-29 12:00:00")
    rel = Release.open!(created_at: created)
    rel.stamp_stage!("qa_deployed", at: created + 5.minutes) # an upstream boundary is stamped

    # confirming's OWN start is missing; the nearest earlier stamp is qa_deployed_at
    # (a stage starts no sooner than the latest upstream boundary). A LATER stamp is
    # never borrowed as a start.
    assert_equal created + 5.minutes, rel.stage_started_at_or_before("confirming")
    # testing sits before any stamp → floors at the release's open time, never nil.
    assert_equal created, rel.stage_started_at_or_before("testing")
  end

  test "[unit] stage_started_at_or_before rejects an unknown stage" do
    assert_raises(ArgumentError) { Release.open!.stage_started_at_or_before("warp") }
  end

  test "[unit] current_stage is monotonic — a late upstream stamp never regresses it" do
    rel = Release.open!
    rel.stamp_stage!("qa_deployed")
    assert_equal "qa_deployed", rel.current_stage

    rel.stamp_stage!("assembled") # the conductor's post-QA-boot assemble! lands late
    assert_equal "qa_deployed", rel.reload.current_stage
    assert rel.stage_reached?("assembled")
    assert_not rel.stage_reached?("confirming"), "the Avi handoff is NOT implied by Live on QA"
  end

  test "[unit] record_event! stamps the mapped stage at the event's occurred_at" do
    rel = Release.open!
    at = 30.minutes.ago.change(usec: 0)
    rel.record_event!(step: "deploy_qa", status: "started", source: "conductor", occurred_at: at)
    assert_equal at, rel.reload.qa_deploy_started_at
    assert_equal "qa_deploying", rel.current_stage
  end

  test "[unit] record_event! ignores failed + unmapped steps for stamping" do
    rel = Release.open!
    rel.record_event!(step: "deploy_qa", status: "failed", source: "conductor")
    rel.record_event!(step: "release_notes", status: "completed", source: "conductor")
    assert_nil rel.reload.current_stage
  end

  test "[unit] a deploy_prod completion event can NOT stamp a release shipped" do
    rel = Release.open!
    rel.record_event!(step: "deploy_prod", status: "completed", source: "conductor")
    assert_nil rel.reload.shipped_at, "shipped is only ever stamped by ship!"
    assert_equal "assembling", rel.state
  end

  test "[unit] the Steffon→Avi handoff: qa_deployed leaves confirming unstamped until its own start" do
    rel = Release.open!
    rel.record_event!(step: "deploy_qa", status: "completed", source: "conductor")
    assert rel.reload.stage_reached?("qa_deployed")
    assert_not rel.stage_reached?("confirming")

    rel.record_event!(step: "ship_gate", status: "started", source: "api", actor: "avi")
    assert rel.reload.stage_reached?("confirming")
    assert_equal "confirming", rel.current_stage
  end

  test "[unit] ship! keeps an earlier confirmed_at stamp (first-write-wins)" do
    rel = Release.open!
    confirmed = 20.minutes.ago.change(usec: 0)
    rel.stamp_stage!("confirmed", at: confirmed)
    rel.ship!(by: "avi")
    assert_equal confirmed, rel.reload.confirmed_at
    assert_equal "avi", rel.confirmed_by
    assert rel.shipped_at.present?
    assert_equal "shipped", rel.current_stage
  end

  test "[unit] a shipped STATE reads as the terminal stage even without stamps (legacy rows)" do
    rel = Release.open!
    rel.ship!
    rel.update_columns(shipped_at: nil)
    assert_equal "shipped", rel.reload.current_stage
    assert rel.stage_reached?("confirmed")
  end

  test "[unit] reopen! winds the timeline back to assembling for the re-QA" do
    rel = Release.open!
    rel.stamp_stage!("assembling")
    rel.record_event!(step: "deploy_qa", status: "completed", source: "conductor")
    rel.assemble!
    rel.update!(confirming_started_at: 1.minute.ago)

    rel.reopen!
    rel.reload
    assert_equal "assembling", rel.state
    assert_equal "assembling", rel.current_stage, "downstream stamps must clear for the re-assembly"
    assert_nil rel.assembled_at
    assert_nil rel.qa_deployed_at
    assert_nil rel.confirming_started_at
    assert rel.assembling_started_at.present?, "the candidate keeps its true assembly origin"

    rel.assemble!
    assert rel.reload.assembled_at.present?, "the re-assembly stamps fresh"
  end

  # --- deployment table spans -------------------------------------------------

  test "review_tests events stamp the testing/tested stage timeline" do
    rel = Release.open!
    # Mirror bin/release's record_release_event: source "conductor" (no usage required).
    rel.record_event!(step: "review_tests", status: "started", source: "conductor")
    assert rel.reload.testing_started_at.present?, "review_tests started stamps testing_started_at"
    assert_nil rel.tested_at

    rel.record_event!(step: "review_tests", status: "completed", source: "conductor")
    assert rel.reload.tested_at.present?, "review_tests completed stamps tested_at"
  end

  test "deployment_stage_span reports completed/in_progress/missing off the stamp pair" do
    now = Time.zone.parse("2026-07-07 18:00:00")
    rel = Release.create!(slug: "rel-span-shipped", branch: "release", state: "shipped")
    rel.update_columns( # rubocop:disable Rails/SkipsModelValidations
      created_at: now - 60.minutes,
      assembling_started_at: now - 40.minutes, assembled_at: now - 25.minutes,
      shipped_at: now
    )

    assembled = rel.deployment_stage_span("assembled")
    assert_equal "completed", assembled[:status]
    assert_equal 15.minutes.to_i, assembled[:seconds]
    assert_equal rel.assembling_started_at, assembled[:started_at]

    # Never-started stage → missing (renders "—"), even on a shipped release.
    assert_equal "missing", rel.deployment_stage_span("tested")[:status]
    assert_nil rel.deployment_stage_span("tested")[:seconds]

    # An active release mid-stage → in_progress (the cell ticks a live count-up).
    active = Release.create!(slug: "rel-span-active", branch: "release", state: "assembling")
    active.update_columns(assembling_started_at: now - 10.minutes) # rubocop:disable Rails/SkipsModelValidations
    span = active.deployment_stage_span("assembled")
    assert_equal "in_progress", span[:status]
    assert_nil span[:seconds], "an in-progress span has no fixed duration — it counts up client-side"
  end

  test "deployment_total_span is created -> shipped, in_progress while active" do
    now = Time.zone.parse("2026-07-07 18:00:00")
    shipped = Release.create!(slug: "rel-total-shipped", branch: "release", state: "shipped")
    shipped.update_columns(created_at: now - 90.minutes, shipped_at: now) # rubocop:disable Rails/SkipsModelValidations
    total = shipped.deployment_total_span
    assert_equal "completed", total[:status]
    assert_equal 90.minutes.to_i, total[:seconds]

    active = Release.create!(slug: "rel-total-active", branch: "release", state: "assembling")
    assert_equal "in_progress", active.deployment_total_span[:status]
  end

  test "deployment_stage_averages averages each stage + total over recent shipped releases" do
    now = Time.zone.parse("2026-07-07 18:00:00")
    [10, 30].each_with_index do |assembled_minutes, index|
      shipped_at = now - (index * 5).minutes # distinct ship times → deterministic order
      rel = Release.create!(slug: "rel-avg-#{index}", branch: "release", state: "shipped")
      rel.update_columns( # rubocop:disable Rails/SkipsModelValidations
        created_at: shipped_at - 2.hours, # anchored to ship so Total is exactly 2h for both
        assembling_started_at: shipped_at - 90.minutes,
        assembled_at: shipped_at - (90 - assembled_minutes).minutes,
        shipped_at: shipped_at
      )
    end

    averages = Release.deployment_stage_averages(limit: 10)
    assert_equal 2, averages["sample_count"]
    assert_equal "Assembled", averages.dig("stages", "assembled", "label")
    assert_equal 20.minutes.to_i, averages.dig("stages", "assembled", "average_seconds") # (10 + 30) / 2
    assert_equal 2.hours.to_i, averages.dig("stages", "total", "average_seconds")
  end
end
