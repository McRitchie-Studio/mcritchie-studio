require "test_helper"
require "minitest/mock"

class Release::ConductorTest < ActiveSupport::TestCase
  # A reviewed task with a KNOWN app repo. Repo-aware eligibility (see
  # validate_members!) refuses a member whose repo is in neither registry
  # section, so the default member here must classify to a known kind. The label
  # is wrapped into a 3-5 word title so it satisfies the naming-discipline rule.
  def reviewed_task(label = "default", repo: "mcritchie-studio")
    Task.create!(title: "reviewable #{label} demo task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [repo] } })
  end

  # A NOT-yet-reviewed task (the incident shape: a PR awaiting review). Carries a
  # known repo so it classifies + adopts cleanly once the review gate is bypassed.
  def submitted_task(label = "default", repo: "mcritchie-studio")
    Task.create!(title: "submitted #{label} demo task", stage: "submitted",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [repo] } })
  end

  test "prepare! opens a new release when none is active, sweeps, and flips on QA-green" do
    t = reviewed_task
    rel = Release::Conductor.prepare!(task_slugs: [t.slug], slug: "rel-test-new")

    assert_equal "rel-test-new", rel.slug
    assert_equal "release", rel.branch # the persistent per-repo release branch
    assert_equal "assembled", rel.state
    assert_equal "assembled", t.reload.stage
    assert_equal Task::MERGED_RELEASE, t.merged
    assert_includes rel.tasks.pluck(:slug), t.slug
  end

  # --- sweep_candidates (qa-deploy step 1: detect the work) ---

  test "[unit] sweep_candidates detects reviewed tasks and assembled stragglers" do
    r = reviewed_task("queue")
    straggler = Task.create!(title: "straggler assembled leftover task", stage: "assembled",
                             merged: Task::MERGED_RELEASE,
                             metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })

    cands = Release::Conductor.sweep_candidates

    assert_includes cands["reviewed"].map(&:slug), r.slug
    assert_includes cands["stragglers"].map(&:slug), straggler.slug
  end

  test "[unit] sweep_candidates excludes an assembled member of the CURRENT release (not a straggler)" do
    member = reviewed_task("member")
    rel = Release::Conductor.sweep!(member)
    Release::Conductor.qa_green!(rel) # member → assembled, attached to the active RC

    cands = Release::Conductor.sweep_candidates

    refute_includes cands["stragglers"].map(&:slug), member.slug,
                    "an assembled member riding the active RC is not a straggler"
    refute_includes cands["reviewed"].map(&:slug), member.slug
  end

  test "[unit] sweep_candidates with NO active release treats every assembled task as a straggler" do
    orphan = Task.create!(title: "orphan assembled task here", stage: "assembled",
                          metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    assert_nil Release.current

    cands = Release::Conductor.sweep_candidates

    assert_includes cands["stragglers"].map(&:slug), orphan.slug
  end

  test "[unit] sweep_candidates is empty when nothing is reviewed and nothing straggles (the no-op signal)" do
    cands = Release::Conductor.sweep_candidates
    assert_empty cands["reviewed"]
    assert_empty cands["stragglers"]
  end

  # --- sweep! (qa-deploy step 3: membership WITHOUT the stage flip) ---

  test "[unit] sweep! attaches the task with merged:release but does NOT move its stage" do
    assert_nil Release.current
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)

    assert_equal rel, Release.current
    assert_equal "assembling", rel.state
    assert_equal "reviewed", t.reload.stage, "the stage flip waits for QA-green"
    assert_equal Task::MERGED_RELEASE, t.merged
    assert_includes rel.tasks.pluck(:slug), t.slug
  end

  test "[unit] sweep! records an assembly intent (the assembly window opens at sweep)" do
    t = reviewed_task
    Release::Conductor.sweep!(t)

    intent = t.reload.task_events.chronological.to_a.find { |e| e.intent? && e.to_stage == "assembled" }
    assert_not_nil intent, "the sweep opens the assembled intent"
    assert_equal "conductor", intent.source
  end

  test "[unit] sweep! re-attaches an assembled straggler without moving it" do
    straggler = Task.create!(title: "straggler assembled leftover task", stage: "assembled",
                             merged: Task::MERGED_RELEASE,
                             metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })

    rel = Release::Conductor.sweep!(straggler)

    assert_equal rel.slug, straggler.reload.release_slug
    assert_equal "assembled", straggler.stage, "a straggler re-rides without moving"
    assert_equal Task::MERGED_RELEASE, straggler.merged
  end

  test "[unit] sweep! never regresses a merged:main member back to release (interrupted Avi)" do
    rel = Release.open!
    t = Task.create!(title: "mid ship interrupted task", stage: "assembled",
                     release_slug: rel.slug, merged: Task::MERGED_MAIN,
                     metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })

    Release::Conductor.sweep!(t)

    assert_equal Task::MERGED_MAIN, t.reload.merged, "sweep! must not undo the ff'd-to-main stamp"
  end

  test "[unit] sweep! heals an attached member missing its merged stamp (pre-field row)" do
    rel = Release.open!
    t = Task.create!(title: "legacy attached member task", stage: "reviewed", release_slug: rel.slug,
                     metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    assert_nil t.merged

    Release::Conductor.sweep!(t)

    assert_equal Task::MERGED_RELEASE, t.reload.merged, "the sweep backfills the git-location"
  end

  # --- qa_green! (qa-deploy step 6: the reviewed→assembled flip) ---

  test "[unit] qa_green! flips swept reviewed members to assembled and assembles the RC" do
    a = reviewed_task("alpha")
    b = reviewed_task("bravo")
    rel = Release::Conductor.sweep!(a)
    Release::Conductor.sweep!(b)
    assert_equal %w[reviewed reviewed], [a.reload.stage, b.reload.stage]

    Release::Conductor.qa_green!(rel)

    assert_equal "assembled", rel.reload.state
    assert_equal %w[assembled assembled], [a.reload.stage, b.reload.stage]
    assert_equal [Task::MERGED_RELEASE, Task::MERGED_RELEASE], [a.merged, b.merged],
                 "merged stays release — main comes at ship's ff"
  end

  test "[unit] qa_green! is idempotent — a re-run moves nothing twice" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    Release::Conductor.qa_green!(rel)
    before = t.reload.task_events.transitions.count

    assert_nothing_raised { Release::Conductor.qa_green!(rel.reload) }
    assert_equal before, t.reload.task_events.transitions.count, "no duplicate assembled transition"
    assert_equal "assembled", rel.reload.state
  end

  test "[unit] a QA failure flips nothing — members stay reviewed for the next self-healing run" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    # qa_green! is simply never called on a failed QA deploy — assert the resting state.
    assert_equal "reviewed", t.reload.stage
    assert_equal Task::MERGED_RELEASE, t.merged, "the merge is retained (skip re-merging on the next run)"
    assert_equal "assembling", rel.reload.state
  end

  # --- deploy-side usage capture (model/tokens/cost on the conductor flips) ---
  # bin/release captures the per-transition delta from its LOCAL transcript and
  # threads it in; these prove it lands on the assembled/shipped TaskEvents.

  test "qa_green! stamps the assembled TaskEvent with the threaded usage" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    Release::Conductor.qa_green!(
      rel, usage_by_slug: { t.slug => { "model" => "claude-opus-4-8", "tokens_in" => 1200, "tokens_out" => 300, "cost" => "0.0125" } }
    )

    event = t.reload.task_events.transitions.find_by(to_stage: "assembled")
    refute_nil event
    assert event.usage?
    assert_equal "claude-opus-4-8", event.model
    assert_equal 1200, event.tokens_in
    assert_equal 300, event.tokens_out
    assert_equal "0.0125".to_d, event.cost
  end

  test "qa_green! without usage records the assembled spine only (no fabrication)" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    Release::Conductor.qa_green!(rel)

    event = t.reload.task_events.transitions.find_by(to_stage: "assembled")
    refute event.usage?, "no usage threaded → deterministic spine only"
  end

  test "qa_green! clears the usage after each flip so it can't leak to a later transition" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    Release::Conductor.qa_green!(rel, usage_by_slug: { t.slug => { "model" => "claude-opus-4-8", "tokens_in" => 10, "tokens_out" => 5 } })

    assert_nil Current.task_event_model, "usage is reset after the flip (batched flip safety)"
    assert_nil Current.task_event_tokens_in
  end

  test "ship! stamps each member's shipped TaskEvent with its own usage" do
    a = reviewed_task("alpha")
    b = reviewed_task("bravo")
    rel = Release::Conductor.prepare!(task_slugs: [a.slug, b.slug])

    Release::Conductor.ship!(
      release: rel, deployed_sha: "abc1234", by: "avi",
      usage_by_slug: {
        a.slug => { "model" => "claude-opus-4-8", "tokens_in" => 500, "tokens_out" => 100, "cost" => "0.005" },
        b.slug => { "model" => "claude-sonnet-4-6", "tokens_in" => 200, "tokens_out" => 50 }
      }
    )

    ea = a.reload.task_events.transitions.find_by(to_stage: "shipped")
    eb = b.reload.task_events.transitions.find_by(to_stage: "shipped")
    assert_equal "claude-opus-4-8", ea.model
    assert_equal 500, ea.tokens_in
    assert_equal "0.005".to_d, ea.cost
    assert_equal "claude-sonnet-4-6", eb.model
    assert_equal 200, eb.tokens_in
    assert_nil eb.cost, "no cost given for b → not fabricated"
  end

  test "ship! with no usage map records the shipped spine only" do
    t = reviewed_task
    rel = Release::Conductor.prepare!(task_slugs: [t.slug])
    Release::Conductor.ship!(release: rel, deployed_sha: "deadbee", by: "avi")

    event = t.reload.task_events.transitions.find_by(to_stage: "shipped")
    refute event.usage?
  end

  test "sweep! attaches to the existing active release" do
    first = reviewed_task("first")
    rel = Release::Conductor.sweep!(first)
    Release::Conductor.sweep!(reviewed_task("second"))

    assert_equal 2, rel.reload.tasks.count
  end

  test "sweep! is idempotent — re-sweeping an already-swept task is a no-op (interrupted Steffon skips)" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    again = Release::Conductor.sweep!(t)

    assert_equal rel.id, again.id
    assert_equal 1, again.tasks.count
    assert_equal "reviewed", t.reload.stage
  end

  test "sweep! reopens an assembled (QA-green) RC so a late sweep re-QAs" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task("first").slug])
    assert_equal "assembled", rel.state

    Release::Conductor.sweep!(reviewed_task("late"))

    assert_equal "assembling", rel.reload.state # reopened to re-assemble + re-QA
    assert_equal 2, rel.tasks.count
  end

  test "sweep! raises on a task that is not sweepable" do
    designed = Task.create!(title: "designed task not reviewed") # stage: designed
    assert_raises(ArgumentError) { Release::Conductor.sweep!(designed) }
  end

  test "sweep! on an already-swept member of an assembled RC is a no-op (no reopen)" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task("member").slug])
    member = rel.reload.tasks.first
    assert_equal "assembled", rel.state
    assert_equal "assembled", member.stage

    Release::Conductor.sweep!(member)

    assert_equal "assembled", rel.reload.state, "re-sweeping a green member must NOT reopen the QA'd RC"
    assert_equal "assembled", member.reload.stage
    assert_equal 1, rel.tasks.count
  end

  # --- screen_merge: the pre-flight review-gate decision (bin/release merge) ---
  # The guard that stops an unreviewed PR being merged onto `release` by accident
  # (the incident: PR #138 merged straight in during the scheduled wait).

  test "screen_merge passes a reviewed task as eligible and reports proceed" do
    t = reviewed_task
    screen = Release::Conductor.screen_merge([t.slug])

    assert_equal "eligible", screen["rows"].first["status"]
    assert_equal "reviewed", screen["rows"].first["stage"]
    assert_empty screen["blocked"]
    assert screen["proceed"]
  end

  test "screen_merge passes an assembled straggler as eligible (it re-rides the next RC)" do
    straggler = Task.create!(title: "straggler assembled leftover task", stage: "assembled",
                             metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    screen = Release::Conductor.screen_merge([straggler.slug])

    assert_equal "eligible", screen["rows"].first["status"]
    assert screen["proceed"]
  end

  test "screen_merge BLOCKS a not-yet-reviewed task and refuses to proceed" do
    t = submitted_task
    screen = Release::Conductor.screen_merge([t.slug])

    assert_equal "blocked", screen["rows"].first["status"]
    assert_equal "submitted", screen["rows"].first["stage"]
    assert_equal [t.slug], screen["blocked"]
    refute screen["proceed"], "an unreviewed task aborts the run"
  end

  test "screen_merge with override reclassifies an unreviewed task as overridden and proceeds" do
    t = submitted_task
    screen = Release::Conductor.screen_merge([t.slug], override: true)

    assert_equal "overridden", screen["rows"].first["status"]
    assert_equal [t.slug], screen["overridden"]
    assert_empty screen["blocked"]
    assert screen["proceed"]
  end

  test "screen_merge flags a missing slug" do
    screen = Release::Conductor.screen_merge(["no-such-task"])

    assert_equal "missing", screen["rows"].first["status"]
    assert_equal ["no-such-task"], screen["missing"]
  end

  test "screen_merge — one unreviewed task in a mixed batch blocks the whole run" do
    ok  = reviewed_task("ok")
    bad = submitted_task("bad")
    screen = Release::Conductor.screen_merge([ok.slug, bad.slug])

    assert_equal [bad.slug], screen["blocked"]
    refute screen["proceed"], "any blocked slug aborts the batch"
  end

  # --- sweep!(override:) — the audited review-gate bypass ---

  test "sweep! still RAISES on a not-sweepable task without override" do
    assert_raises(ArgumentError) { Release::Conductor.sweep!(submitted_task) }
  end

  test "sweep! with override flips a not-reviewed task to reviewed and attaches it" do
    t = submitted_task
    rel = Release::Conductor.sweep!(t, override: true)

    assert_equal "reviewed", t.reload.stage, "the override stands in for review — QA-green still owns assembled"
    assert_equal Task::MERGED_RELEASE, t.merged
    assert_includes rel.tasks.pluck(:slug), t.slug
  end

  test "sweep! with override records a review_bypassed event on the audit spine" do
    t = submitted_task
    Release::Conductor.sweep!(t, override: true)

    ev = t.reload.task_events.transitions.where(to_stage: "reviewed").order(:occurred_at).last
    assert ev.metadata["review_bypassed"], "the bypassed flip is recorded on the task's spine"
    assert_equal "submitted", ev.from_stage, "the event names the stage the gate was skipped from"
  end

  test "sweep! override on an already-reviewed task records NO bypass (override is a no-op there)" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t, override: true)
    Release::Conductor.qa_green!(rel)

    ev = t.reload.task_events.transitions.where(to_stage: "assembled").last
    refute ev.metadata["review_bypassed"], "a reviewed task rides normally — no bypass marker"
  end

  test "sweep! does not leak the bypass flag onto a later normal transition" do
    rel = Release::Conductor.sweep!(submitted_task("bypassed"), override: true)
    # A subsequent NORMAL sweep + flip must not inherit the flag — the Current
    # marker is reset in sweep!'s ensure.
    normal = reviewed_task("normal")
    Release::Conductor.sweep!(normal)
    Release::Conductor.qa_green!(rel.reload)

    ev = normal.reload.task_events.transitions.where(to_stage: "assembled").last
    refute ev.metadata["review_bypassed"], "Current flag is reset in ensure — no leak"
  end

  # --- eject! (block-on-regression: pull ONE offender off the RC, keep the rest) ---

  test "[unit] eject! detaches and blocks the offender while the rest of the RC rides on" do
    good = reviewed_task("good")
    bad  = reviewed_task("bad")
    rel = Release::Conductor.sweep!(good)
    Release::Conductor.sweep!(bad)

    Release::Conductor.eject!(bad, feedback: "integration regression on origin/release")

    bad.reload
    assert_equal "blocked", bad.stage
    assert_equal "rework", bad.devops_field("block_kind")
    assert_nil bad.release_slug, "the offender is OFF the candidate"
    assert_nil bad.merged, "cleared — pairs with the documented merge-commit revert"
    note = Activity.for_task(bad).by_type("qa_feedback").last
    assert_equal "integration regression on origin/release", note.description

    good.reload
    assert_equal "reviewed", good.stage, "the rest of the RC is untouched"
    assert_equal rel.slug, good.release_slug
    assert_equal Task::MERGED_RELEASE, good.merged
    assert_equal [good.slug], rel.reload.tasks.pluck(:slug)
  end

  test "[unit] eject! without feedback blocks with no qa_feedback note" do
    bad = reviewed_task("quiet")
    Release::Conductor.sweep!(bad)
    before = Activity.for_task(bad).by_type("qa_feedback").count

    Release::Conductor.eject!(bad)

    assert_equal "blocked", bad.reload.stage
    assert_equal before, Activity.for_task(bad).by_type("qa_feedback").count
  end

  # --- record_merged! (Avi's ff→main stamp) ---

  test "[unit] record_merged! stamps merged:main on the named members" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    Release::Conductor.qa_green!(rel)

    Release::Conductor.record_merged!(slugs: [t.slug], merged: "main")

    t.reload
    assert_equal "assembled", t.stage, "the stage flip to shipped is ship!'s — this is just the git-location"
    assert_equal Task::MERGED_MAIN, t.merged
  end

  test "[unit] record_merged! rejects an unknown git location" do
    t = reviewed_task
    Release::Conductor.sweep!(t)
    assert_raises(ActiveRecord::RecordInvalid) do
      Release::Conductor.record_merged!(slugs: [t.slug], merged: "somewhere")
    end
  end

  # --- the merged-field matrix, end to end (the crash-recovery spine) ---

  test "[integration] the merged matrix walks nil→release→main across sweep, QA-green, ff, and ship" do
    t = reviewed_task("matrix")
    assert_nil t.merged                                       # reviewed + nil    = not swept

    rel = Release::Conductor.sweep!(t)
    assert_equal %w[reviewed release], [t.reload.stage, t.merged]   # swept / QA-in-flight

    Release::Conductor.qa_green!(rel)
    assert_equal %w[assembled release], [t.reload.stage, t.merged]  # QA-green, waiting on Avi

    Release::Conductor.record_merged!(slugs: [t.slug], merged: "main")
    assert_equal %w[assembled main], [t.reload.stage, t.merged]     # ff'd, prod-deploy in flight

    Release::Conductor.ship!(release: rel.reload, deployed_sha: "abc1234", by: "avi")
    assert_equal %w[shipped main], [t.reload.stage, t.merged]       # done
  end

  test "[integration] an interrupted qa-deploy resumes: the re-sweep skips nothing it shouldn't and the flip completes" do
    # Crash shape: the sweep recorded (reviewed + merged:release) but QA never
    # went green. The next self-healing run re-sweeps (a no-op) and flips on green.
    t = reviewed_task("interrupted")
    rel = Release::Conductor.sweep!(t)
    assert_equal %w[reviewed release], [t.reload.stage, t.merged]

    again = Release::Conductor.sweep!(t.reload) # the next run's sweep — must no-op
    assert_equal rel.id, again.id
    assert_equal 1, again.tasks.count

    Release::Conductor.qa_green!(again)
    assert_equal %w[assembled release], [t.reload.stage, t.merged]
  end

  test "prepare! is additive — extends the active release instead of opening a second" do
    first = reviewed_task("first")
    rel1 = Release::Conductor.prepare!(task_slugs: [first.slug], slug: "rel-test-a")

    second = reviewed_task("second")
    rel2 = Release::Conductor.prepare!(task_slugs: [second.slug], slug: "rel-test-b") # slug ignored: active exists

    assert_equal rel1.id, rel2.id
    assert_equal "rel-test-a", rel2.slug
    assert_equal 2, rel2.tasks.count
    assert_equal "assembled", rel2.state
  end

  test "prepare! reopens an assembled RC to absorb new work, then re-assembles" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task("first").slug])
    assert_equal "assembled", rel.state

    again = Release::Conductor.prepare!(task_slugs: [reviewed_task("second").slug])

    assert_equal rel.id, again.id
    assert_equal 2, again.tasks.count
    assert_equal "assembled", again.reload.state
  end

  test "prepare! skips tasks already on the release (idempotent)" do
    t = reviewed_task
    Release::Conductor.prepare!(task_slugs: [t.slug])
    rel = Release::Conductor.prepare!(task_slugs: [t.slug])

    assert_equal 1, rel.tasks.count
  end

  test "prepare! raises on a task that is not reviewed" do
    designed = Task.create!(title: "designed task not reviewed") # stage: designed
    assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [designed.slug]) }
  end

  # --- curate! / qa_green! (the boot-gated split of prepare!) ---
  # The CLI defers the QA-green flip until wait_for_boot confirms QA is up, so
  # the two halves are separately callable: curate! sweeps + validates without
  # flipping anything, qa_green! flips members + RC only after boot.

  test "curate! sweeps the named tasks but flips NOTHING (release assembling, members reviewed)" do
    t = reviewed_task
    rel = Release::Conductor.curate!(task_slugs: [t.slug], slug: "rel-curate")

    assert_equal "rel-curate", rel.slug
    assert_equal "assembling", rel.state, "curate! must NOT assemble — that's deferred until QA is green"
    assert_equal "reviewed", t.reload.stage, "the member flip waits for QA-green too"
    assert_equal Task::MERGED_RELEASE, t.merged
    assert_includes rel.tasks.pluck(:slug), t.slug
  end

  test "[unit] curate! with no slugs auto-sweeps the whole detected queue (reviewed + stragglers)" do
    queued = reviewed_task("queued")
    straggler = Task.create!(title: "straggler assembled leftover task", stage: "assembled",
                             merged: Task::MERGED_RELEASE,
                             metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })

    rel = Release::Conductor.curate!(task_slugs: [])

    assert_not_nil rel, "detected work opens a candidate"
    assert_equal [queued.slug, straggler.slug].sort, rel.tasks.pluck(:slug).sort
    assert_equal "reviewed", queued.reload.stage
    assert_equal "assembled", straggler.reload.stage, "a straggler re-rides without moving"
  end

  test "curate! is a no-op returning nil when nothing is detected and nothing is active" do
    assert_nil Release::Conductor.curate!(task_slugs: [])
    assert_equal 0, Release.count
  end

  test "curate! validates members — an unknown-repo member raises and rolls back" do
    bad = Task.create!(title: "unknown repo member task", stage: "reviewed",
                       metadata: { "devops" => { "shape" => "backend", "repositories" => ["not-a-real-repo"] } })
    assert_raises(ArgumentError) { Release::Conductor.curate!(task_slugs: [bad.slug], slug: "rel-bad") }

    # curate! is called STANDALONE by `bin/release prepare` (no outer txn), so its
    # OWN transaction must roll the half-curation back — open! + sweep! already ran
    # before validate_members! raised. Without that wrapper a stranded RC sits on
    # the board and the single-active-release rule blocks every other session.
    assert_equal 0, Release.count, "a failed curate! must not strand a half-curated release"
    assert_nil Release.current, "no active candidate left after the rollback"
    assert_equal "reviewed", bad.reload.stage, "the rolled-back member stays reviewed"
    assert_nil bad.merged, "the rolled-back member's merged stamp is rolled back too"
  end

  test "assemble! flips a swept RC assembling→assembled (idempotent)" do
    rel = Release::Conductor.curate!(task_slugs: [reviewed_task.slug], slug: "rel-asm")
    assert_equal "assembling", rel.state

    Release::Conductor.assemble!(rel)
    assert_equal "assembled", rel.reload.state
    assert_equal %w[started completed], rel.release_events.for_step("qa_smoke").chronological.pluck(:status)

    # Re-running against an already-assembled RC is a no-op, not an error.
    assert_nothing_raised { Release::Conductor.assemble!(rel) }
    assert_equal "assembled", rel.reload.state
    assert_equal 2, rel.release_events.for_step("qa_smoke").count
  end

  test "prepare! is atomic — a non-sweepable task rolls back the new release" do
    designed = Task.create!(title: "designed task not reviewed")
    assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [designed.slug]) }
    assert_equal 0, Release.count, "a failed prepare! must not leave a dangling release"
  end

  test "prepare! with nothing detected and nothing active is an idempotent no-op" do
    # No reviewed work, no stragglers, no active release → nil, and NO release is
    # fabricated (the heartbeat's schedule-ready no-op property).
    assert_nil Release::Conductor.prepare!(task_slugs: [])
    assert_equal 0, Release.count
  end

  test "[integration] prepare! self-heals — the bare call sweeps the whole reviewed queue and flips it on green" do
    member = reviewed_task("member")
    Release::Conductor.sweep!(member) # already swept by a prior (interrupted) run
    newcomer = reviewed_task("newcomer") # reviewed since — the sweep must pick it up

    rel = Release::Conductor.prepare!(task_slugs: [])

    assert_equal "assembled", rel.state
    assert_equal [member.slug, newcomer.slug].sort, rel.tasks.pluck(:slug).sort
    assert_equal "assembled", newcomer.reload.stage, "the newcomer rode the same self-healing run"
    assert_equal "assembled", member.reload.stage
  end

  test "prepare! is idempotent against an already-assembled RC" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    assert_equal "assembled", rel.state

    again = Release::Conductor.prepare!(task_slugs: [])

    assert_equal rel.id, again.id
    assert_equal "assembled", again.state
  end

  test "ship! stamps the deployed sha + url and flips the RC and members to shipped" do
    t = reviewed_task
    rel = Release::Conductor.prepare!(task_slugs: [t.slug])

    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234", by: "alex", production_url: "https://example.test")

    assert_equal "shipped", rel.reload.state
    assert_equal "abc1234", rel.deployed_sha
    assert_equal "https://example.test", rel.production_url
    assert_equal "alex", rel.confirmed_by
    assert_equal "shipped", t.reload.stage
    assert_equal %w[started completed], rel.release_events.for_step("deploy_prod").chronological.pluck(:status)
  end

  test "eligible_task_slugs lists reviewed tasks" do
    a = reviewed_task("a")
    b = reviewed_task("b")
    slugs = Release::Conductor.eligible_task_slugs

    assert_includes slugs, a.slug
    assert_includes slugs, b.slug
  end

  # --- producer-first ordering + member_plan ---

  def gem_task(label = "engine", repo: "studio-engine")
    Task.create!(title: "gem #{label} release task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "library", "repositories" => [repo] } })
  end

  def app_task(label = "app", repo: "mcritchie-studio", branch: "feat/x", deps: [])
    Task.create!(title: "app #{label} release task", stage: "reviewed", dependencies: deps,
                 metadata: { "devops" => {
                   "shape" => "backend", "repositories" => [repo], "branch" => branch,
                   "pr_url" => "https://github.com/amcritchie/#{repo}/pull/1"
                 } })
  end

  test "prepare! adds members producer-first — the gem gets the earlier position" do
    app = app_task("consumer")
    gem = gem_task("engine")
    rel = Release::Conductor.prepare!(task_slugs: [app.slug, gem.slug]) # app passed first

    assert_equal [gem.slug, app.slug], rel.tasks.order(:position).pluck(:slug)
  end

  test "member_plan is producer-first and tags kind/repo/branch/version" do
    gem = gem_task("engine", repo: "studio-engine")
    app = app_task("consumer", repo: "mcritchie-studio", branch: "feat/consume")
    rel = Release::Conductor.prepare!(task_slugs: [gem.slug, app.slug])

    plan = nil
    Release::Repos.stub(:gem_version, ->(repo) { repo == "studio-engine" ? "9.9.9" : nil }) do
      plan = Release::Conductor.member_plan(rel)
    end

    assert_equal [gem.slug, app.slug], plan.map { |m| m[:slug] }
    gem_member, app_member = plan

    assert_equal "gem", gem_member[:kind]
    assert_equal "studio-engine", gem_member[:repo]
    assert_equal "9.9.9", gem_member[:version]
    assert_nil gem_member[:branch]

    assert_equal "app", app_member[:kind]
    assert_equal "mcritchie-studio", app_member[:repo]
    assert_equal "feat/consume", app_member[:branch]
    assert_nil app_member[:version]
  end

  test "member_plan carries each member's post_deploy_cmd (nil when undeclared)" do
    with_cmd = Task.create!(title: "backfill mascots release task", stage: "reviewed",
                            metadata: { "devops" => {
                              "shape" => "backend", "repositories" => ["turf-monster"], "branch" => "feat/x",
                              "pr_url" => "https://github.com/amcritchie/turf-monster/pull/1",
                              "post_deploy_cmd" => "rake pokemon:backfill_mascots"
                            } })
    without = app_task("plain", repo: "mcritchie-studio", branch: "feat/plain")
    rel = Release::Conductor.prepare!(task_slugs: [with_cmd.slug, without.slug])

    plan = Release::Conductor.member_plan(rel)
    declared = plan.find { |m| m[:slug] == with_cmd.slug }
    undeclared = plan.find { |m| m[:slug] == without.slug }

    assert_equal "rake pokemon:backfill_mascots", declared[:post_deploy_cmd]
    assert_nil undeclared[:post_deploy_cmd], "an undeclared post_deploy_cmd is nil, not blank"
  end

  # --- record_post_deploy_check: the [post-deploy] checks_run audit line ---

  test "record_post_deploy_check appends a tagged [post-deploy] outcome line" do
    t = reviewed_task("pd-record")
    Release::Conductor.record_post_deploy_check(
      task_slug: t.slug, app: "turf-monster-qa", cmd: "rake pokemon:backfill_mascots", ok: true
    )

    line = t.reload.devops_checks_run.last
    assert_match(/\A\[post-deploy\] rake pokemon:backfill_mascots on turf-monster-qa → ok/, line)
  end

  test "record_post_deploy_check records a FAILED outcome" do
    t = reviewed_task("pd-fail")
    Release::Conductor.record_post_deploy_check(task_slug: t.slug, app: "turf-monster-mainnet", cmd: "rake boom", ok: false)

    assert_match(/→ FAILED/, t.reload.devops_checks_run.last)
  end

  test "record_post_deploy_check is idempotent — a re-run replaces the prior line for the same cmd+app" do
    t = reviewed_task("pd-idem")
    # First run fails, second (same cmd+app) succeeds — the LAST outcome wins, no pile-up.
    Release::Conductor.record_post_deploy_check(task_slug: t.slug, app: "turf-monster-qa", cmd: "rake x", ok: false)
    Release::Conductor.record_post_deploy_check(task_slug: t.slug, app: "turf-monster-qa", cmd: "rake x", ok: true)

    pd_lines = t.reload.devops_checks_run.select { |l| l.start_with?("[post-deploy] rake x on turf-monster-qa") }
    assert_equal 1, pd_lines.size, "the same cmd+app must not pile up duplicate lines"
    assert_match(/→ ok/, pd_lines.first)
  end

  test "record_post_deploy_check keeps distinct entries for different cmd or app, and preexisting checks" do
    t = Task.create!(title: "preexisting checks demo task", stage: "reviewed",
                     metadata: { "devops" => { "shape" => "backend", "repositories" => ["turf-monster"],
                                               "checks_run" => ["[unit] bin/rails test"] } })
    Release::Conductor.record_post_deploy_check(task_slug: t.slug, app: "turf-monster-qa", cmd: "rake a", ok: true)
    Release::Conductor.record_post_deploy_check(task_slug: t.slug, app: "turf-monster-mainnet", cmd: "rake a", ok: true)

    checks = t.reload.devops_checks_run
    assert_includes checks, "[unit] bin/rails test", "preexisting non-post-deploy checks are preserved"
    assert_equal 2, checks.count { |l| l.start_with?("[post-deploy] rake a on") },
                 "the same cmd on a different app is a distinct entry"
  end

  test "record_post_deploy_check does not write a TaskEvent (no stage change)" do
    t = reviewed_task("pd-noevent")
    before = t.task_events.count
    Release::Conductor.record_post_deploy_check(task_slug: t.slug, app: "turf-monster-qa", cmd: "rake x", ok: true)

    assert_equal before, t.reload.task_events.count, "recording a check must not append a stage event"
  end

  test "ordered_members puts gems before apps regardless of position" do
    rel = Release.open!
    app = app_task("consumer", repo: "mcritchie-studio", branch: "feat/app")
    gem = gem_task("engine", repo: "studio-engine")
    rel.add(app)
    rel.add(gem)
    app.update!(position: 0)
    gem.update!(position: 99) # later position, but a producer → still first

    assert_equal [gem.slug, app.slug], rel.ordered_members.map(&:slug)
  end

  test "ordered_members honors dependencies even against position order" do
    rel = Release.open!
    base = app_task("base", repo: "turf-monster", branch: "feat/base")
    dependent = app_task("dependent", repo: "turf-monster", branch: "feat/dep", deps: [base.slug])
    rel.add(base)
    rel.add(dependent)
    # Force positions so position ALONE would put the dependent first.
    dependent.update!(position: 0)
    base.update!(position: 99)

    assert_equal [base.slug, dependent.slug], rel.ordered_members.map(&:slug),
                 "a task must sort after any task in its dependencies"
  end

  # --- repo_plan: per-repo deploy plan ---

  test "repo_plan groups members by repo, producer-first, with per-repo deploy metadata" do
    gem = gem_task("engine", repo: "studio-engine")
    studio = app_task("studio change", repo: "mcritchie-studio", branch: "feat/studio")
    turf = app_task("turf change", repo: "turf-monster", branch: "feat/turf")
    rel = Release::Conductor.prepare!(task_slugs: [turf.slug, studio.slug, gem.slug], slug: "rel-multi-repo")

    plan = nil
    Release::Repos.stub(:gem_version, ->(repo) { repo == "studio-engine" ? "0.9.0" : nil }) do
      plan = Release::Conductor.repo_plan(rel)
    end

    # Producer-first repo order: the gem repo leads, then apps in member order.
    assert_equal %w[studio-engine mcritchie-studio turf-monster], plan.map { |g| g[:repo] }

    gem_group = plan.find { |g| g[:repo] == "studio-engine" }
    assert_equal :gem, gem_group[:kind]
    assert_equal [gem.slug], gem_group[:members].map { |m| m[:slug] }
    assert_nil gem_group[:release_branch]
    assert_nil gem_group[:qa_app]
    assert_nil gem_group[:prod_deploy]

    studio_group = plan.find { |g| g[:repo] == "mcritchie-studio" }
    assert_equal :app, studio_group[:kind]
    assert_equal [studio.slug], studio_group[:members].map { |m| m[:slug] }
    assert_equal "release", studio_group[:release_branch] # the persistent per-repo branch
    assert_equal "mcritchie-studio", studio_group[:qa_app]
    assert_equal "git_push_heroku", studio_group[:prod_deploy]["strategy"]

    turf_group = plan.find { |g| g[:repo] == "turf-monster" }
    assert_equal :app, turf_group[:kind]
    assert_equal "release", turf_group[:release_branch]
    assert_equal "turf-monster", turf_group[:qa_app]
    assert_equal "repo_script", turf_group[:prod_deploy]["strategy"]
    assert_equal ["--yes"], turf_group[:prod_deploy]["args"]
  end

  test "repo_plan collapses multiple members of one repo into a single group" do
    a = app_task("turf a", repo: "turf-monster", branch: "feat/a")
    b = app_task("turf b", repo: "turf-monster", branch: "feat/b")
    rel = Release::Conductor.prepare!(task_slugs: [a.slug, b.slug], slug: "rel-one-repo")

    plan = Release::Conductor.repo_plan(rel)

    assert_equal 1, plan.length
    assert_equal "turf-monster", plan.first[:repo]
    assert_equal [a.slug, b.slug].sort, plan.first[:members].map { |m| m[:slug] }.sort
  end

  test "repo_plan is JSON-serializable" do
    gem = gem_task("engine", repo: "studio-engine")
    app = app_task("consumer", repo: "turf-monster", branch: "feat/consume")
    rel = Release::Conductor.prepare!(task_slugs: [gem.slug, app.slug], slug: "rel-json")

    plan = nil
    Release::Repos.stub(:gem_version, ->(_repo) { "0.9.0" }) do
      plan = Release::Conductor.repo_plan(rel)
    end

    assert_nothing_raised { JSON.generate(plan) }
  end

  # --- repo-aware eligibility ---

  test "prepare! raises naming a member whose repo is in neither registry section" do
    mystery = Task.create!(title: "mystery repo deploy task", stage: "reviewed",
                           metadata: { "devops" => { "shape" => "backend", "repositories" => ["mystery-repo"] } })

    err = assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [mystery.slug]) }
    assert_match mystery.slug, err.message
    assert_match "mystery-repo", err.message
  end

  test "prepare! eligibility is atomic — an unknown-repo member rolls the release back" do
    mystery = Task.create!(title: "mystery repo deploy task", stage: "reviewed",
                           metadata: { "devops" => { "shape" => "backend", "repositories" => ["mystery-repo"] } })

    assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [mystery.slug]) }
    assert_equal 0, Release.count, "an unknown-repo member must not leave a dangling release"
    assert_equal "reviewed", mystery.reload.stage, "the rolled-back task stays reviewed"
  end

  # --- record_qa_deploy ---

  test "record_qa_deploy stores the qa_url on the release" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_deploy(release: rel, qa_url: "https://qa.example.test")
    assert_equal "https://qa.example.test", rel.reload.qa_url
  end

  # --- record_qa_shas ---

  test "record_qa_shas persists the per-repo deployed SHAs onto the release" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_shas(release: rel, shas: { "mcritchie-studio" => "abc1234", "turf-monster" => "def5678" })

    assert_equal({ "mcritchie-studio" => "abc1234", "turf-monster" => "def5678" }, rel.reload.metadata["qa_shas"])
  end

  test "record_qa_shas persists GEM repo keys too, not just apps (Fix-1 freeze)" do
    # prepare now freezes a gem's origin/release HEAD into qa_shas alongside apps,
    # so the record must round-trip a gem repo key the same way (ship then reads it
    # back via Release::ShipSequence.frozen_sha instead of falling back live).
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_shas(release: rel,
                                      shas: { "studio-engine" => "eng1234", "mcritchie-studio" => "hub5678" })

    assert_equal({ "studio-engine" => "eng1234", "mcritchie-studio" => "hub5678" }, rel.reload.metadata["qa_shas"])
    assert_equal "eng1234", Release::ShipSequence.frozen_sha(rel.metadata["qa_shas"], "studio-engine")
  end

  test "record_qa_shas is non-clobbering — a blank value never wipes a frozen SHA, a non-blank updates, a new key is added" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    # First (full) prepare freezes good SHAs for the gem + the hub app.
    Release::Conductor.record_qa_shas(release: rel,
                                      shas: { "studio-engine" => "gemgood", "mcritchie-studio" => "huboldsha" })

    # A partial re-run from a gem-less box: it can't resolve the gem sibling, so it
    # passes "" for the gem, a NEW non-blank SHA for the hub, and a brand-new repo.
    Release::Conductor.record_qa_shas(release: rel,
                                      shas: { "studio-engine" => "", "mcritchie-studio" => "hubnewsha", "turf-monster" => "turfsha" })

    shas = rel.reload.metadata["qa_shas"]
    assert_equal "gemgood", shas["studio-engine"], "a blank incoming value must NOT clobber a previously-frozen SHA"
    assert_equal "hubnewsha", shas["mcritchie-studio"], "a non-blank value still updates in place"
    assert_equal "turfsha", shas["turf-monster"], "a brand-new repo key is still added"
  end

  # --- post_release_notes (reuses ReleaseNotes::Formatter + DiscordClient) ---

  def shipped_release
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234", by: "alex", production_url: "https://example.test")
    rel
  end

  test "post_release_notes builds the header content + task-card embeds and hands them to the client" do
    rel = shipped_release
    delivered = nil
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { delivered = { content: content, embeds: embeds } }) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert result[:delivered]
      assert result[:message].present?, "still returns the text render for preview"
    end
    assert delivered[:embeds].present?, "a fitting release ships rich embeds"
    assert_equal 1, delivered[:embeds].size, "task cards ONLY — no summary embed prepended"
    # The deploy header rides in `content`: H1 + an H3 masked link to the deploy.
    header = delivered[:content]
    assert header.start_with?("# 🚀 Production Deployment\n### ["), "H1 + H3 masked link"
    assert_includes header, "🪎", "the single-app release shows its app glyph"
    assert_includes header, rel.slug, "the H3 carries the release tag"
    assert_includes header, "](https://example.test)", "the H3 links to the production url"
    assert_equal %w[started completed], rel.release_events.for_step("release_notes").chronological.pluck(:status)
  end

  test "post_release_notes dry_run builds the message without delivering" do
    rel = shipped_release
    called = false
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { called = true }) do
      result = Release::Conductor.post_release_notes(release: rel, dry_run: true)
      assert_not result[:delivered]
      assert result[:message].present?
    end
    assert_not called, "dry_run must not deliver"
  end

  test "post_release_notes is non-fatal when the webhook is missing" do
    rel = shipped_release
    raiser = ->(content: nil, embeds: nil) { raise ReleaseNotes::DiscordClient::MissingWebhook, "no webhook" }
    ReleaseNotes::DiscordClient.stub(:deliver, raiser) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert_not result[:delivered]
      assert result[:message].present?, "still returns the message even if delivery fails"
    end
  end

  test "post_release_notes survives any delivery error (defense-in-depth)" do
    rel = shipped_release
    # Even a raw transport error (the gap Avi caught) must not fail a completed ship.
    raiser = ->(content: nil, embeds: nil) { raise Net::OpenTimeout, "boom" }
    ReleaseNotes::DiscordClient.stub(:deliver, raiser) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert_not result[:delivered]
      assert result[:message].present?
    end
  end

  test "[integration] post_release_notes carries the recorded smoke seal verdict into the notes + Discord" do
    rel = shipped_release
    rel.record_smoke_seal!(Release::SmokeSeal.from_result(passed: true, summary: "@qa-readonly green vs prod"))

    delivered = nil
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { delivered = { content: content, embeds: embeds } }) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert_includes result[:message], "🟢 Production smoke seal: passed — @qa-readonly green vs prod"
    end
    assert_includes delivered[:content], "🟢 Production smoke seal: passed", "the Discord header carries the seal"
  end

  test "[integration] post_release_notes surfaces a RED seal verdict" do
    rel = shipped_release
    rel.record_smoke_seal!(Release::SmokeSeal.from_result(passed: false, summary: "2 specs failed"))

    ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { }) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert_includes result[:message], "🔴 Production smoke seal: FAILED — 2 specs failed"
    end
  end

  test "[integration] post_release_notes omits the seal line for an unsealed release" do
    rel = shipped_release # never sealed
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { }) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert_not_includes result[:message], "Production smoke seal"
    end
  end

  # --- archive_completed! / archivable_completed_slugs (DevOps loop conclusion) ---
  #
  # NOTE: `fixtures :all` seeds a release-less shipped task (tasks(:done_task)),
  # which is itself archivable, so these assert by MEMBERSHIP rather than against
  # the whole archived set. `kept` IS asserted exactly — it's precisely the last
  # release's members.

  # A shipped Release whose member tasks end up `shipped` carrying its slug — the
  # board's read-only "Last Release". Returns [release, reloaded members].
  def shipped_release_with(*labels)
    members = labels.map { |label| reviewed_task(label) }
    rel = Release::Conductor.prepare!(task_slugs: members.map(&:slug))
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234", production_url: "https://example.test")
    [rel, members.map(&:reload)]
  end

  # A shipped task carried by NO release (no release_slug) — a pre-conductor
  # completion. 3-5 word title per the naming rule.
  def loose_shipped_task(label = "loose")
    Task.create!(title: "loose shipped #{label} task", stage: "shipped")
  end

  test "archivable_completed_slugs previews shipped-not-in-last-release, mutating nothing" do
    _rel, members = shipped_release_with("member")
    loose = loose_shipped_task

    slugs = Release::Conductor.archivable_completed_slugs

    assert_includes slugs, loose.slug
    refute_includes slugs, members.first.slug, "a last-release member is NOT archivable"
    assert_equal "shipped", loose.reload.stage, "a preview mutates nothing"
  end

  test "archive_completed! archives shipped tasks NOT in the last release and keeps its members" do
    _rel, members = shipped_release_with("keep-a", "keep-b")
    loose = loose_shipped_task

    result = Release::Conductor.archive_completed!

    assert_includes result[:archived], loose.slug
    assert_equal members.map(&:slug).sort, result[:kept].sort
    members.each { |m| refute_includes result[:archived], m.slug }
    assert_equal "archived", loose.reload.stage
    members.each { |m| assert_equal "shipped", m.reload.stage, "a last-release member stays shipped" }
  end

  test "archive_completed! never touches active or blocked tasks — only shipped" do
    actives = {
      "designed"  => Task.create!(title: "designed demo task here", stage: "designed"),
      "building"  => Task.create!(title: "building demo task here", stage: "building"),
      "submitted" => Task.create!(title: "submitted demo task here", stage: "submitted"),
      "reviewed"  => Task.create!(title: "reviewed demo task here", stage: "reviewed"),
      "assembled" => Task.create!(title: "assembled demo task here", stage: "assembled"),
      "blocked"   => Task.create!(title: "blocked demo task here", stage: "blocked")
    }
    loose = loose_shipped_task

    result = Release::Conductor.archive_completed!

    assert_includes result[:archived], loose.slug, "the shipped task is archived"
    actives.each do |stage, task|
      assert_equal stage, task.reload.stage, "a #{stage} task must be untouched"
      refute_includes result[:archived], task.slug
    end
  end

  test "archive_completed! with no shipped release archives every shipped task" do
    a = loose_shipped_task("a")
    b = loose_shipped_task("b")
    assert_nil Release.last_shipped

    result = Release::Conductor.archive_completed!

    assert_includes result[:archived], a.slug
    assert_includes result[:archived], b.slug
    assert_empty result[:kept], "no last release → nothing kept"
    assert_equal %w[archived archived], [a.reload.stage, b.reload.stage]
  end

  test "archive_completed! archives a release_slug-less (pre-conductor) shipped task, keeps members" do
    _rel, members = shipped_release_with("member")
    legacy = loose_shipped_task("legacy")
    assert_nil legacy.release_slug

    result = Release::Conductor.archive_completed!

    assert_includes result[:archived], legacy.slug
    refute_includes result[:archived], members.first.slug
    assert_equal "archived", legacy.reload.stage
    assert_equal "shipped", members.first.reload.stage
  end

  test "archive_completed! is idempotent — a second run archives nothing new" do
    shipped_release_with("member")
    loose_shipped_task

    first = Release::Conductor.archive_completed!
    assert_operator first[:count], :>=, 1

    second = Release::Conductor.archive_completed!
    assert_equal 0, second[:count]
    assert_empty second[:archived]
  end

  # --- conductor mascot: the deployment wears the running session's Pokémon -----
  # bin/release injects Current.conductor_session_id into the heroku-run payload;
  # the conductor drains it onto the release so the board shows who's working it.

  def seed_pokemon
    %w[bulbasaur charmander squirtle pikachu snorlax dragonite].each_with_index.map do |slug, i|
      Pokemon.create!(dex: 320 + i, name: slug.capitalize, slug: slug, types: %w[normal], generation: 1)
    end
  end

  test "sweep! stamps the conductor session's mascot onto the release" do
    seed_pokemon
    Current.conductor_session_id = "sess-conductor"
    rel = Release::Conductor.sweep!(reviewed_task)

    assert_equal SessionMascot.for("sess-conductor").mascot_slug, rel.reload.devops_field("mascot")
    assert_equal "sess-conductor", rel.devops_field("mascot_session")
  ensure
    Current.conductor_session_id = nil
  end

  test "sweep! leaves the release unmascoted when no conductor session is in context" do
    seed_pokemon
    Current.conductor_session_id = nil
    rel = Release::Conductor.sweep!(reviewed_task)
    assert_nil rel.reload.devops_field("mascot"), "non-conductor callers never stamp"
  end

  test "ship! re-stamps the mascot for the session that ran the deploy (handoff)" do
    seed_pokemon
    Current.conductor_session_id = "sess-merge"
    rel = Release::Conductor.sweep!(reviewed_task)
    Release::Conductor.qa_green!(rel)
    merged_face = rel.reload.devops_field("mascot")
    assert merged_face.present?, "the sweeping session stamped a face"

    Current.conductor_session_id = "sess-ship"
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234")

    assert_equal "shipped", rel.reload.state
    assert_equal "sess-ship", rel.devops_field("mascot_session"), "the shipping session takes the face"
    refute_equal merged_face, rel.devops_field("mascot")
  ensure
    Current.conductor_session_id = nil
  end

  # --- record_deploy_intents! (the live Deploy-lane crew ticker) ----------------
  # bin/release prepare auto-records the Steffon → assembled QA intent; bin/release
  # ship the Avi → shipped intent. The Deploy mirror of bin/reviewer-select's review
  # intent — so /deployments shows who's on it live with NO hand-run bin/task intent
  # (the 2026-06-25 unfilled-ship-slot incident).

  # An assembled (QA-green) release with the given member — what ship fires over.
  def green_release_with(task)
    rel = Release::Conductor.sweep!(task)
    Release::Conductor.qa_green!(rel)
    rel.reload
  end

  test "record_deploy_intents! records the Avi shipped intent for every member (what ship fires)" do
    rel = green_release_with(reviewed_task("alpha"))
    Release::Conductor.sweep!(reviewed_task("beta"))
    Release::Conductor.qa_green!(rel.reload)

    slugs = Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi")

    assert_equal rel.tasks.pluck(:slug).sort, slugs.sort, "every member gets an open shipped intent"
    rel.tasks.each do |t|
      intent = t.open_intent_for("shipped")
      assert intent.present?, "#{t.slug} carries an open shipped intent"
      assert_equal "avi", intent.actor
    end
  end

  test "record_deploy_intents! defaults the actor to the stage's role owner (Avi ships, Steffon QAs)" do
    rel = green_release_with(reviewed_task("shipper"))
    member = rel.tasks.first

    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped") # actor nil → avi
    assert_equal "avi", member.reload.open_intent_for("shipped").actor

    # A member still at `reviewed` (swept, flip pending — THE standard shape at
    # prepare time now) defaults to Steffon, the QA owner.
    pending = reviewed_task("pending")
    Release::Conductor.sweep!(pending) # attached, still reviewed
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled") # actor nil → steffon
    assert_equal "steffon", pending.reload.open_intent_for("assembled").actor
  end

  test "record_deploy_intents! is idempotent — a re-run reuses the open intent, never stacks" do
    rel = green_release_with(reviewed_task)
    member = rel.tasks.first

    first  = Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi")
    second = Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi")

    assert_equal first, second, "the same open intent is reused"
    assert_equal 1, member.reload.task_events.intents.where(to_stage: "shipped").count
  end

  test "prepare's QA intent still records on an ALREADY-assembled member (straggler / re-run)" do
    # A member past the QA-green flip (a straggler re-riding, or a prepare re-run)
    # already has the assembled transition, so prepare's QA call must NOT no-op. It
    # records a QA intent that rides toward `shipped` (superseded by the SHIP, not
    # the flip) carrying the `qa` marker, so the board renders Steffon QA-ing live.
    rel = green_release_with(reviewed_task)
    member = rel.tasks.first
    assert_equal "assembled", member.stage, "guard: the QA-green flip landed"

    slugs = Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "steffon")
    assert_equal [member.slug], slugs, "the QA intent is recorded even though the assembled transition landed"

    qa = member.reload.open_intent_for("shipped")
    assert qa.present?, "the QA intent rides toward shipped — superseded by the ship, not the flip"
    assert_equal "steffon", qa.actor
    assert qa.metadata["qa"], "marked as the QA-lane intent, distinct from Avi's ship intent"

    # Idempotent: a re-run reuses the open QA intent, never stacks a second row.
    again = Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "steffon")
    assert_equal slugs, again
    assert_equal 1, member.reload.task_events.intents.where(to_stage: "shipped").count
  end

  test "record_deploy_intents! is superseded by the real transition (QA by the flip, ship by ship!)" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t) # swept, still reviewed — the standard prepare shape
    member = rel.tasks.first
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "steffon") # QA intent
    assert member.reload.open_intent_for("assembled").present?, "the plain QA intent renders on a reviewed member"

    Release::Conductor.qa_green!(rel.reload) # the flip supersedes the QA intent
    assert_nil member.reload.open_intent_for("assembled"), "qa_green!'s assembled transition supersedes the QA intent"

    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi") # ship intent
    assert member.reload.open_intent_for("shipped").present?, "an open intent toward shipped while still assembled"

    Release::Conductor.ship!(release: rel.reload, deployed_sha: "abc1234")

    # The shipped transition supersedes the ship intent (and any straggling QA one).
    assert_nil member.reload.open_intent_for("shipped"), "ship! supersedes every open shipped intent"
    assert_empty Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi"),
                 "a shipped member's ship call no-ops"
    assert_empty Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "steffon"),
                 "a shipped member's QA call no-ops too (toward assembled, transition long landed)"
  end

  test "record_deploy_intents! returns [] for a nil release" do
    assert_empty Release::Conductor.record_deploy_intents!(nil, to_stage: "shipped", actor: "avi")
  end
end
