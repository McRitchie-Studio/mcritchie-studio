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

  test "[unit] sweep_candidates detects a NULL-release_slug assembled task WHILE a release is active" do
    # The NULL guard's boundary, tested where it actually bites: with a release ACTIVE, an
    # assembled task carrying NO release_slug (pre-conductor / detached work) must STILL be a
    # straggler — SQL `release_slug != 'rel'` is NULL (not true) for a null row, so it would be
    # silently dropped WITHOUT the explicit `release_slug IS NULL OR`. Mutation evidence: delete
    # that clause and this null-slug straggler VANISHES from the sweep while a release is active,
    # stranding it forever. Every other straggler test either has no active release (the `if
    # release` clause is skipped) or excludes a NON-null slug — neither observes the NULL drop.
    member = reviewed_task("member")
    rel = Release::Conductor.sweep!(member)
    Release::Conductor.qa_green!(rel)
    assert Release.current, "a release must be active for this boundary"

    orphan = Task.create!(title: "detached null slug assembled task", stage: "assembled",
                          metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    assert_nil orphan.release_slug, "the boundary needs a genuinely null release_slug"

    cands = Release::Conductor.sweep_candidates

    assert_includes cands["stragglers"].map(&:slug), orphan.slug,
                    "a null-release_slug assembled task is a straggler even while a release is active"
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

  test "[unit] sweep! preserves merged:main on a CROSS-release straggler (re-adopt never downgrades)" do
    # Unlike the test above, this straggler belongs to a PRIOR (terminal) release,
    # so sweep!'s current-member short-circuit never fires — the no-downgrade
    # guard in Release#add is what keeps the never-regress promise absolute.
    prior = Release.open!
    t = Task.create!(title: "prior cycle interrupted task", stage: "assembled",
                     release_slug: prior.slug, merged: Task::MERGED_MAIN,
                     metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    prior.update!(state: "shipped") # closed without flipping the member

    rel = Release::Conductor.sweep!(t)

    assert_equal rel.slug, t.reload.release_slug, "the straggler re-rides the new RC"
    assert_equal Task::MERGED_MAIN, t.merged, "add's backstop keeps the ff'd-to-main stamp"
    assert_equal "assembled", t.stage, "re-adoption still never moves the stage"
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

  test "[unit] qa_green! revives tested_at — stamped once, first-write-wins" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    assert_nil rel.reload.tested_at, "tested_at is blank until QA green"

    Release::Conductor.qa_green!(rel)
    rel.reload
    stamped = rel.tested_at
    refute_nil stamped, "qa_green! stamps the release's QA-tested moment"

    refute_nil rel.assembled_at, "qa_green! assembles the RC"

    # DELIBERATELY no wall-clock ordering assertion. The release stamps are a
    # LOGICAL stage order, not a chronology: assembling_started_at is stamped back
    # at MERGE time (sweep!) and qa_deploy_started_at before the QA deploy, so both
    # precede tested_at in wall-clock even though Release::STAGES lists them after
    # it. Asserting `tested_at <= assembled_at` would pin the ONE pair that happens
    # to hold (both are written inside this transaction) and imply a chronology the
    # system does not guarantee. The real contract — release_timeline projects
    # Release::STAGES order — is asserted in test/db/timeline_views_test.rb.

    # First-write-wins like the other release stage stamps: a re-run never moves it.
    Release::Conductor.qa_green!(rel.reload)
    assert_equal stamped, rel.reload.tested_at, "tested_at is first-write-wins"
  end

  test "[unit] a QA failure flips nothing — members stay reviewed for the next self-healing run" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    # qa_green! is simply never called on a failed QA deploy — assert the resting state.
    assert_equal "reviewed", t.reload.stage
    assert_equal Task::MERGED_RELEASE, t.merged, "the merge is retained (skip re-merging on the next run)"
    assert_equal "assembling", rel.reload.state
  end

  # --- Live-on-QA stamp is ATOMIC with the member flip (regression) ---
  # deploy_qa:completed ("Live on QA" green) used to be stamped by bin/release a
  # step BEFORE this flip (record_qa_deploy), so the /deployments tracker showed a
  # green Live-on-QA while the members were still `reviewed`. qa_green! now owns
  # the stamp so the tracker can never reach `qa_deployed` before the members do.

  test "[unit] qa_green! with a qa_url stamps Live-on-QA atomic with the flip" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    refute rel.stage_reached?("qa_deployed"), "not live before the flip"

    Release::Conductor.qa_green!(rel, qa_url: "https://qa.example.test")

    assert_equal "assembled", t.reload.stage, "member flipped"
    assert rel.reload.stage_reached?("qa_deployed"), "Live-on-QA stamped in the same call as the flip"
    assert_equal "https://qa.example.test", rel.release_events.where(step: "deploy_qa", status: "completed").last&.url
  end

  test "[unit] qa_green! falls back to the release's recorded qa_url for the deploy_qa stamp" do
    t = reviewed_task
    rel = Release::Conductor.sweep!(t)
    Release::Conductor.record_qa_url(release: rel, qa_url: "https://qa.example.test") # step-7 URL write

    Release::Conductor.qa_green!(rel.reload) # no explicit qa_url — falls back to release.qa_url

    assert_equal "assembled", t.reload.stage
    assert_equal "https://qa.example.test",
                 rel.reload.release_events.where(step: "deploy_qa", status: "completed").last&.url,
                 "the recorded qa_url flows into the deploy_qa:completed stamp via the fallback"
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
    assert_equal "building", bad.stage, "a block is a building attribute now"
    assert bad.blocked?
    assert_equal "rework", bad.block_kind
    assert_equal "avi", bad.blocked_by, "eject is Avi's — it runs during his qa-release sweep"
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

    assert_equal "building", bad.reload.stage
    assert bad.blocked?
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
                   "pr_url" => "https://github.com/McRitchie-Studio/#{repo}/pull/1"
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
                              "pr_url" => "https://github.com/McRitchie-Studio/turf-monster/pull/1",
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
    assert_equal "github_actions", studio_group[:prod_deploy]["strategy"] # DevOps v2 Phase 2: hub ships via Actions

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

  # --- record_qa_url ---

  test "[unit] record_qa_url stores the qa_url WITHOUT stamping Live-on-QA" do
    # sweep! (NOT prepare!) so qa_green! hasn't run yet — this isolates the step-7
    # URL write, the exact window the old record_qa_deploy lit Live-on-QA green in.
    rel = Release::Conductor.sweep!(reviewed_task)
    Release::Conductor.record_qa_url(release: rel, qa_url: "https://qa.example.test")
    rel.reload

    assert_equal "https://qa.example.test", rel.qa_url
    refute rel.stage_reached?("qa_deployed"),
           "record_qa_url records the URL only — the deploy_qa:completed stamp is qa_green!'s job"
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

  # --- record_qa_gate: the G3 verdict + its auditor ---

  test "record_qa_gate persists what the gate certified AND the CI verdict for the same SHA" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_gate(release: rel, repo: "mcritchie-studio", sha: "abc1234", cmd: "bin/rails test",
                                      ok: true, ci: { "state" => "green", "count" => 3 })

    gate = rel.reload.metadata["qa_gates"]["mcritchie-studio"]
    assert_equal({ "sha" => "abc1234", "cmd" => "bin/rails test", "ok" => true,
                   "ci" => { "state" => "green", "count" => 3 } }, gate)
  end

  test "record_qa_gate records a DISAGREEMENT — a green gate beside a red CI, and G4 stops self-gating on it" do
    # The alarm that scrolled past in the conductor's terminal is not evidence; the
    # pair on the release is. A red auditor never un-certifies the LOCAL gate (`ok`
    # stays true — CI audits, it does not veto) and it never blocks a ship. What it
    # DOES do is cost the certification its 90/10 privilege: G4 no longer skips its
    # suite on a SHA GitHub CI called broken. Fail-OPEN — more checking, never less.
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_gate(release: rel, repo: "turf-monster", sha: "def5678", cmd: "bin/rails test",
                                      ok: true, ci: { state: :red, checks: ["test:system"] })

    gate = rel.reload.metadata["qa_gates"]["turf-monster"]
    assert gate["ok"], "the LOCAL gate stays the verdict — a red auditor does not flip it"
    assert_equal "red", gate.dig("ci", "state").to_s
    assert_equal ["test:system"], gate.dig("ci", "checks")
    assert_not Release::ShipSequence.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "def5678",
                                                    qa_gate: gate),
               "the record ARMS G4 in the safe direction: a certification CI contradicts must not let the " \
               "ship gate skip its own suite (that skip is what made G3's alarm the ONLY thing between a " \
               "CI-red SHA and production)"
  end

  test "record_qa_gate: an AGREEING (green) auditor leaves G4's self-gating intact" do
    # The fail-open must be armed by a red and NOTHING else — otherwise the
    # cross-check would tax every ship with a redundant suite run.
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_gate(release: rel, repo: "mcritchie-studio", sha: "abc1234", cmd: "bin/rails test",
                                      ok: true, ci: { "state" => "green", "count" => 4 })

    gate = rel.reload.metadata["qa_gates"]["mcritchie-studio"]
    assert Release::ShipSequence.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc1234", qa_gate: gate),
           "both verdicts agree — the 90/10 batch certification still holds"
  end

  test "record_qa_gate omits the ci key when the auditor was not consulted" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_gate(release: rel, repo: "mcritchie-studio", sha: "abc1234", cmd: "bin/rails test",
                                      ok: true)

    gate = rel.reload.metadata["qa_gates"]["mcritchie-studio"]
    refute gate.key?("ci"), "no CI verdict recorded is not the same as a CI verdict of nothing"
    assert gate["ok"]
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
      "assembled" => Task.create!(title: "assembled demo task here", stage: "assembled")
    }
    # A blocked task is a `building` task with a live block — still active, so
    # archive must leave it alone too.
    blocked = Task.create!(title: "blocked demo task here", stage: "building")
    blocked.block!(by: "avi", kind: "rework")
    loose = loose_shipped_task

    result = Release::Conductor.archive_completed!

    assert_includes result[:archived], loose.slug, "the shipped task is archived"
    actives.each do |stage, task|
      assert_equal stage, task.reload.stage, "a #{stage} task must be untouched"
      refute_includes result[:archived], task.slug
    end
    assert_equal "building", blocked.reload.stage, "a blocked (building) task is untouched"
    assert blocked.blocked?
    refute_includes result[:archived], blocked.slug
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
  # bin/release prepare auto-records the Avi → assembled QA intent; bin/release
  # ship the Steffon → shipped intent. The Deploy mirror of bin/reviewer-select's review
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

  test "record_deploy_intents! defaults the actor to the stage's role owner (Steffon ships, Avi QAs)" do
    rel = green_release_with(reviewed_task("shipper"))
    member = rel.tasks.first

    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped") # actor nil → steffon
    assert_equal "steffon", member.reload.open_intent_for("shipped").actor

    # A member still at `reviewed` (swept, flip pending — THE standard shape at
    # prepare time now) defaults to Avi, the QA owner.
    pending = reviewed_task("pending")
    Release::Conductor.sweep!(pending) # attached, still reviewed
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled") # actor nil → avi
    assert_equal "avi", pending.reload.open_intent_for("assembled").actor
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
