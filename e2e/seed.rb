# Seed test database for Playwright smoke tests.
# Run with: RAILS_ENV=test bin/rails runner e2e/seed.rb
#
# Idempotent — clears and recreates all test data.

puts "Seeding test database for Playwright..."

# Clear in dependency order
ActionGrade.delete_all # FK child of atomic_actions — clear before the parent
AtomicAction.delete_all
AtomicEvent.delete_all # narrated spans; actions nullify their FK on delete
Activity.delete_all
SkillAssignment.delete_all
Task.delete_all
Skill.delete_all
Agent.delete_all
Usage.delete_all
ErrorLog.delete_all
User.delete_all
CoachRanking.delete_all
Coach.delete_all
Team.delete_all
Person.delete_all
GateRun.delete_all # slug-keyed, no FK — delete_all wipes above skip callbacks, so stale runs would otherwise survive reseeds and inflate attempt counts
Release.delete_all
SessionMascot.delete_all
Pokemon.delete_all

# Admin user
admin = User.create!(
  name: "Alex Test",
  email: "alex@test.com",
  role: "admin"
)

# Agents
alex = Agent.create!(
  name: "Alex",
  slug: "alex",
  status: "active",
  agent_type: "orchestrator",
  title: "Lead Orchestrator",
  description: "Coordinates all agents and manages task assignment."
)

mack = Agent.create!(
  name: "Mack",
  slug: "mack",
  status: "active",
  agent_type: "worker",
  title: "General Worker",
  description: "Versatile worker handling data scraping and processing."
)

# Senior reviewers + the deploy-lane owners, so the consolidated timeline can
# resolve avatars for the review pair (Carl/Shannon), Steffon (QA → assembled),
# and Avi (ship → shipped).
Agent.create!(name: "Carl", slug: "carl", status: "active", agent_type: "specialist", title: "Backend Expert")
Agent.create!(name: "Shannon", slug: "shannon", status: "active", agent_type: "specialist", title: "UI Expert")
Agent.create!(name: "Steffon", slug: "steffon", status: "active", agent_type: "specialist", title: "Platform Engineer")
Agent.create!(name: "Avi", slug: "avi", status: "active", agent_type: "product", title: "Product Owner")

# Skills
scraping = Skill.create!(name: "Web Scraping", slug: "web-scraping", category: "data", description: "Extract data from websites")
rails_dev = Skill.create!(name: "Rails Development", slug: "rails-development", category: "development", description: "Build Rails applications")

SkillAssignment.create!(agent_slug: "alex", skill_slug: "rails-development")
SkillAssignment.create!(agent_slug: "mack", skill_slug: "web-scraping")

# Tasks in different workflow stages
Task.create!(title: "Review agent protocol", description: "Audit inter-agent messaging patterns.", stage: "designed", priority: 0, agent_slug: "alex")
Task.create!(title: "Scrape odds data", description: "Pull latest odds from sportsbooks.", stage: "building", priority: 1, agent_slug: "mack", queued_at: 1.day.ago, started_at: 2.hours.ago)
Task.create!(title: "Deploy v2 release", description: "Deploy latest version to production.", stage: "submitted", priority: 2, agent_slug: "alex", queued_at: 3.days.ago, started_at: 2.days.ago)
Task.create!(
  title: "Sidebar back-navigation production repro",
  slug: "task-ea8541e4b5b6",
  description: "Fixture for the production sidebar back-navigation regression.",
  stage: "blocked",
  priority: 1,
  agent_slug: "alex"
)

# Session-resume fixture: a task claimed by a Claude session — drives the …<last4>
# badge + click-to-copy resume control on the /tasks board.
Task.create!(
  title: "Resume session demo task",
  slug: "session-resume-demo",
  description: "Fixture for the session-resume board widget (last-4 + resume copy).",
  stage: "building",
  priority: 0,
  agent_slug: "alex",
  metadata: { "devops" => {
    "kind" => "feature",
    "repositories" => ["mcritchie-studio"],
    "session_id" => "00000000-0000-0000-0000-00000012ab",
    "session_provider" => "claude"
  } }
)

# Activities
Activity.create!(agent_slug: "alex", activity_type: "task_assigned", description: "Assigned scrape task to Mack")
Activity.create!(agent_slug: "mack", activity_type: "task_started", description: "Started scraping odds data")

coach_person = Person.create!(
  first_name: "Sean",
  last_name: "McDermott",
  slug: "sean-mcdermott",
  coach: true
)

coach_team = Team.create!(
  name: "Buffalo Bills",
  short_name: "BUF",
  mascot: "Bills",
  slug: "buffalo-bills",
  location: "Buffalo",
  sport: "football",
  league: "nfl",
  conference: "AFC",
  division: "East"
)

Coach.create!(
  person_slug: coach_person.slug,
  team_slug: coach_team.slug,
  role: "head_coach",
  lean: "defense",
  sport: "football"
)

# Stage-change timeline demo: one task walked through a full lifecycle, carrying
# the per-transition usage agents report. Drives the Stage Timeline section on
# the task show page — durations are measured server-side, model/tokens/cost are
# agent-reported (best-effort).
timeline_task = Task.create!(
  title: "Timeline walkthrough demo",
  slug: "timeline-demo",
  description: "Fixture for the task Stage Timeline — genesis, transitions, durations, and reported model cost.",
  stage: "reviewed",
  priority: 1,
  agent_slug: "alex",
  metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio"] } }
)
timeline_task.task_events.delete_all # replace the auto-genesis with a curated, time-spaced sequence
[
  { from: nil,         to: "designed",  at: 6.hours.ago,              secs: nil,  src: "web" },
  { from: "designed",  to: "building",  at: 5.hours.ago,              secs: 3600, src: "cli",
    model: "claude-opus-4-8", tin: 18_000,  tout: 42_000, cost: "0.61" },
  { from: "building",  to: "submitted", at: 2.5.hours.ago,           secs: 9000, src: "cli",
    model: "claude-opus-4-8", tin: 240_000, tout: 96_000, cost: "5.40" },
  { from: "submitted", to: "reviewed",  at: 40.minutes.ago,          secs: 6600, src: "web", actor: "avi" }
].each do |e|
  timeline_task.task_events.create!(
    from_stage: e[:from], to_stage: e[:to], occurred_at: e[:at], seconds_in_from: e[:secs],
    source: e[:src], actor: e[:actor], model: e[:model],
    tokens_in: e[:tin], tokens_out: e[:tout], cost: e[:cost]
  )
end

# Agentic-intent demo: a SUBMITTED task whose review has started — Avi picked the
# pair, recorded as an OPEN review intent — so the consolidated timeline shows a
# live in-progress block with both seniors ticking, before the →reviewed
# transition lands. Drives the intent/live-ticker assertions.
intent_task = Task.create!(
  title: "Agentic intent live review",
  slug: "intent-demo",
  description: "Fixture for the agentic-intent live block — the senior pair reviewing now.",
  stage: "submitted",
  priority: 1,
  agent_slug: "alex",
  metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio"] } }
)
intent_task.record_intent_event(
  to_stage: "reviewed",
  reviewers: [{ "slug" => "carl", "weight" => "heavy" }, { "slug" => "shannon", "weight" => "light" }],
  source: "cli"
)

# Live-updates demo: a submitted task that WALKED designed→building→submitted with
# an actor (so its deploy card renders a crew) but has NO intent yet — so its card
# starts WITHOUT a live ticker. The /deployments websockets e2e records a review
# intent against it after page load and asserts the ticker appears with no reload.
Current.task_event_actor = "carl"
live_task = Task.create!(
  title: "Live cable update demo",
  slug: "live-cable-demo",
  description: "Fixture for the /deployments live-update round-trip (record an intent → card updates live).",
  stage: "designed",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio"] } }
)
live_task.update!(stage: "building")
live_task.update!(stage: "submitted")
Current.reset

# Re-review live-update demo: the task completed one review, got blocked for
# rework, rebuilt, and re-entered `submitted`. Its card starts with a historical
# static review duration; recording a fresh review intent must replace that with
# the current live review ticker.
rereview_task = Task.create!(
  title: "Live rereview demo card",
  slug: "live-rereview-demo",
  description: "Fixture for resubmitted PR review intent replacing an old review duration.",
  stage: "submitted",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "bug", "repositories" => ["mcritchie-studio"] } }
)
rereview_task.task_events.delete_all
[
  { from: nil,         to: "designed",  at: 6.hours.ago,      secs: nil,        actor: "carl" },
  { from: "designed",  to: "building",  at: 5.hours.ago,      secs: 3600,       actor: "shannon" },
  { from: "building",  to: "submitted", at: 4.hours.ago,      secs: 3600,       actor: "shannon" },
  { from: "submitted", to: "reviewed",  at: 3.hours.ago,      secs: 21.minutes,
    meta: { "reviewers" => [{ "slug" => "shannon", "weight" => "heavy" }, { "slug" => "carl", "weight" => "light" }] } },
  { from: "reviewed",  to: "blocked",   at: 2.hours.ago,      secs: 3600 },
  { from: "blocked",   to: "building",  at: 1.hour.ago,       secs: 3600,       actor: "carl" },
  { from: "building",  to: "submitted", at: 20.minutes.ago,   secs: 2400,       actor: "carl" }
].each do |e|
  rereview_task.task_events.create!(
    from_stage: e[:from], to_stage: e[:to], occurred_at: e[:at], seconds_in_from: e[:secs],
    source: "cli", actor: e[:actor], metadata: e[:meta] || {}
  )
end

# Direct-block stale-intent demo: review started, but the reviewer blocked the PR
# directly from `submitted` before the reviewed transition landed. After rebuild
# and resubmit, the old intent must be closed; the e2e posts a fresh review intent
# and expects the live ticker to start only then.
direct_block_task = Task.create!(
  title: "Live direct block card",
  slug: "live-direct-block-demo",
  description: "Fixture for stale review intent invalidation after direct rework block.",
  stage: "submitted",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "bug", "repositories" => ["mcritchie-studio"] } }
)
direct_block_task.task_events.delete_all
reviewers = [{ "slug" => "shannon", "weight" => "primary" }, { "slug" => "carl", "weight" => "light" }]
[
  { kind: TaskEvent::TRANSITION, from: nil,         to: "designed",  at: 5.hours.ago,    secs: nil,  actor: "carl" },
  { kind: TaskEvent::TRANSITION, from: "designed",  to: "building",  at: 4.hours.ago,    secs: 3600, actor: "shannon" },
  { kind: TaskEvent::TRANSITION, from: "building",  to: "submitted", at: 3.hours.ago,    secs: 3600, actor: "shannon" },
  { kind: TaskEvent::INTENT,     from: "submitted", to: "reviewed",  at: 2.hours.ago,    secs: nil,  meta: { "reviewers" => reviewers } },
  { kind: TaskEvent::TRANSITION, from: "submitted", to: "blocked",   at: 90.minutes.ago, secs: 1800 },
  { kind: TaskEvent::TRANSITION, from: "blocked",   to: "building",  at: 1.hour.ago,     secs: 1800, actor: "carl" },
  { kind: TaskEvent::TRANSITION, from: "building",  to: "submitted", at: 20.minutes.ago, secs: 2400, actor: "carl" }
].each do |e|
  direct_block_task.task_events.create!(
    kind: e[:kind], from_stage: e[:from], to_stage: e[:to], occurred_at: e[:at],
    seconds_in_from: e[:secs], source: "cli", actor: e[:actor], metadata: e[:meta] || {}
  )
end

# Cleared-block re-review demo: a task that was QA-blocked (a qa_feedback Activity),
# had the block resolved (a resolves_feedback handoff), and is back in `submitted`
# awaiting a re-review — Task#block_state => :cleared, so the card wears the amber
# tone + RE-REVIEW badge (distinct from red UNRESOLVED and plain never-blocked).
cleared_block_task = Task.create!(
  title: "Cleared block re-review demo",
  slug: "e2e-cleared-block-demo",
  description: "A resolved QA block back in submitted, awaiting another review.",
  stage: "submitted",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "bug", "repositories" => ["mcritchie-studio"] } }
)
Activity.create!(task_slug: cleared_block_task.slug, activity_type: "qa_feedback",
                 description: "Blocked: please add a regression test.", created_at: 2.hours.ago)
Activity.create!(task_slug: cleared_block_task.slug, activity_type: "handoff",
                 description: "Added the regression test — ready for another review.",
                 metadata: { "resolves_feedback" => true }, created_at: 20.minutes.ago)

# A second submitted task for the live STAGE-CHANGE round-trip: the e2e moves it
# submitted→reviewed and asserts the card FLIPs columns AND the per-column count
# badges update (the regression guard for the updateCounts() call in applyLiveUpdate).
Current.task_event_actor = "carl"
move_task = Task.create!(
  title: "Live cable move demo",
  slug: "live-cable-move-demo",
  description: "Fixture for the /deployments live stage-change round-trip (move → card FLIPs + counts update).",
  stage: "designed",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio"] } }
)
move_task.update!(stage: "building")
move_task.update!(stage: "submitted")
Current.reset

# A Building task for the blocked-card websocket regression. The e2e removes its
# stale DOM card before moving it building→blocked; the broadcast must still
# prepend the blocked card back into the visual Building dropzone.
Task.create!(
  title: "Live blocked demo card",
  slug: "live-blocked-demo",
  description: "Fixture for the /deployments live block transition round-trip.",
  stage: "building",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "bug", "repositories" => ["mcritchie-studio"] } }
)

# Same blocked transition, but with the card still visible in the Building
# dropzone. This guards the same-dropzone duplicate-id path: a delayed animated
# remove must not delete the freshly prepended blocked replacement card.
Task.create!(
  title: "Live blocked visible demo",
  slug: "live-blocked-visible-demo",
  description: "Fixture for the /deployments visible-card building→blocked round-trip.",
  stage: "building",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "bug", "repositories" => ["mcritchie-studio"] } }
)

# Same regression, but on the Build board. /tasks used to render the card on page
# load but never subscribed to the live stream, so a building→blocked move in
# another session left the open board stale.
Task.create!(
  title: "Tasks blocked demo card",
  slug: "tasks-live-blocked-demo",
  description: "Fixture for the /tasks live block transition round-trip.",
  stage: "building",
  priority: 1,
  agent_slug: "carl",
  metadata: { "devops" => { "kind" => "bug", "repositories" => ["mcritchie-studio"] } }
)

# Live deploy-crew demo: an ASSEMBLED task that walked the full build → review →
# assembled journey (with actors) but has NO ship intent yet — so its card renders the
# fixed four-lane crew with the fourth (deploy) slot RESERVED but EMPTY. The
# /deployments live-update e2e records a ship intent (Avi deploying) against it after
# page load and asserts the deploy slot fills with a live ticker, with no page reload.
deploy_crew_task = Task.create!(
  title: "Live deploy crew demo",
  slug: "live-deploy-crew-demo",
  description: "Fixture for the assembled-column deploy-crew live-update (record a ship intent → 4th slot fills live).",
  stage: "assembled",
  priority: 1,
  agent_slug: "shannon",
  metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio"] } }
)
deploy_crew_task.task_events.delete_all # curated, time-spaced build → review → assembled spine
[
  { from: nil,         to: "designed",  at: 7.hours.ago,    secs: nil,  actor: "carl" },
  { from: "designed",  to: "building",  at: 6.hours.ago,    secs: 3600, actor: "shannon" },
  { from: "building",  to: "submitted", at: 5.hours.ago,    secs: 5400, actor: "shannon" },
  { from: "submitted", to: "reviewed",  at: 4.hours.ago,    secs: 3600,
    meta: { "reviewers" => [{ "slug" => "shannon", "weight" => "heavy" }, { "slug" => "carl", "weight" => "light" }] } },
  { from: "reviewed",  to: "assembled", at: 35.minutes.ago, secs: 1800, actor: "steffon" }
].each do |e|
  deploy_crew_task.task_events.create!(
    from_stage: e[:from], to_stage: e[:to], occurred_at: e[:at], seconds_in_from: e[:secs],
    source: "cli", actor: e[:actor], metadata: e[:meta] || {}
  )
end

# /deployments release cards: each release wears the conductor SESSION's Pokémon
# mascot + a timing line. Drives the release_mascot e2e — an ACTIVE Next Release
# (in progress) and a SHIPPED Last Release (took ~18m), each with a stamped mascot.
# A 1x1 transparent GIF data URI so the browser renders the avatar with NO network
# fetch — a real http(s) sprite would log an ERR_NAME_NOT_RESOLVED console error
# that the strict deployments_live pageErrors assertion would (rightly) catch.
sprite = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: ["normal"], generation: 1,
                sprite_url: sprite)
Pokemon.create!(dex: 149, name: "Dragonite", slug: "dragonite", types: ["dragon", "flying"], generation: 1,
                sprite_url: sprite)

# Shiny mascot demo: a building card whose session draw came up SHINY — drives
# the shiny_mascot e2e (the board crew circle must paint the shiny sprite, a
# GOLD 1x1 data URI distinct from the transparent normal one). Stamped directly
# (update_columns) so the fixture is deterministic, not a 1-in-2 roll.
shiny_sprite = "data:image/gif;base64,R0lGODlhAQABAPAAAP/XAAAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw=="
Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", types: ["electric"], generation: 1,
                sprite_url: sprite, shiny_sprite_url: shiny_sprite)
shiny_task = Task.create!(title: "Shiny mascot demo card", slug: "shiny-mascot-demo",
                          stage: "building", priority: 1, started_at: 21.minutes.ago)
shiny_task.update_columns(metadata: shiny_task.metadata.deep_merge(
  "devops" => { "mascot" => "pikachu", "mascot_shiny" => true, "mascot_session" => "sess-shiny" }
))

def release_member!(release, slug:, title:)
  task = Task.create!(
    title: title,
    slug: slug,
    stage: "reviewed",
    priority: 1,
    metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio"] } }
  )
  release.add(task)
end

def stamp_tracker_stage_history!(release, shipped_at:, assembling_seconds: 10.minutes)
  testing_seconds = 1.minute
  qa_seconds = 3.minutes
  confirming_seconds = 2.minutes
  prod_seconds = 2.minutes
  total_seconds = testing_seconds + assembling_seconds + qa_seconds + confirming_seconds + prod_seconds
  testing_started_at = shipped_at - total_seconds
  assembling_started_at = testing_started_at + testing_seconds
  assembled_at = assembling_started_at + assembling_seconds
  qa_deploy_started_at = assembled_at
  qa_deployed_at = qa_deploy_started_at + qa_seconds
  confirming_started_at = qa_deployed_at
  confirmed_at = confirming_started_at + confirming_seconds
  prod_deploy_started_at = confirmed_at

  release.update_columns( # rubocop:disable Rails/SkipsModelValidations
    created_at: testing_started_at,
    updated_at: shipped_at,
    testing_started_at: testing_started_at,
    assembling_started_at: assembling_started_at,
    assembled_at: assembled_at,
    qa_deploy_started_at: qa_deploy_started_at,
    qa_deployed_at: qa_deployed_at,
    confirming_started_at: confirming_started_at,
    confirmed_at: confirmed_at,
    prod_deploy_started_at: prod_deploy_started_at,
    shipped_at: shipped_at
  )
end

# Shipped first (terminal) so the active release below satisfies the singleton.
2.times do |index|
  history = Release.create!(slug: "rel-e2e-countdown-#{index + 1}", branch: "release", state: "shipped")
  stamp_tracker_stage_history!(history, shipped_at: (3 - index).hours.ago)
end

shipped_release = Release.open!
shipped_release.update!(metadata: { "devops" => { "mascot" => "dragonite", "mascot_session" => "sess-ship" } })
[
  ["release-stack-last-a", "Release Autonomy Cleanup"],
  ["release-stack-last-b", "Release Progress Tracker"],
  ["release-stack-last-c", "Auto-record deploy lane intents"]
].each { |slug, title| release_member!(shipped_release, slug: slug, title: title) }
shipped_release.ship!
stamp_tracker_stage_history!(shipped_release, shipped_at: Time.current)
# A 🟢 post-ship production smoke seal on the Last Release, so the deployments e2e
# can assert the seal badge renders (the @qa-readonly suite passed against prod).
shipped_release.record_smoke_seal!(
  Release::SmokeSeal.from_result(passed: true, summary: "@qa-readonly green vs https://app.mcritchie.studio")
)

# Release-grain testing gates on the Last Release, so /deployments/all renders
# the gate-backed G3/G4 columns: a G3 Candidate that failed attempt 1 (a QA app
# never booted) and passed attempt 2 — exercising the ×2 retry badge — and a
# passed G4 Ship carrying the prod-smoke seal as its closing SOP + metadata.
# Windows sit inside the tracker stamps above (assembling → shipped ≈ the last
# 31 minutes). Idempotent: GateRun.delete_all at the top clears prior seeds
# (delete_all wipes skip dependent callbacks — the Task A round-1 lesson).
gate_now = Time.current
GateRun.close!(subject_type: "release", subject_slug: shipped_release.slug, key: "g3_candidate",
               success: false, source: "seed", actor: "steffon",
               metadata: { "reason" => "1 app(s) never returned /up 200" },
               sops: [{ "sop" => "pre_qa_gate", "cmd" => "bin/rails test", "result" => "pass", "duration_ms" => 412_000 },
                      { "sop" => "qa_up_smoke", "cmd" => "curl /up", "result" => "fail", "duration_ms" => 120_000 }],
               now: gate_now - 27.minutes)
GateRun.open!(subject_type: "release", subject_slug: shipped_release.slug, key: "g3_candidate",
              source: "seed", actor: "steffon", now: gate_now - 26.minutes)
GateRun.close!(subject_type: "release", subject_slug: shipped_release.slug, key: "g3_candidate",
               success: true, source: "seed", actor: "steffon",
               sops: [{ "sop" => "pre_qa_gate", "cmd" => "bin/rails test", "result" => "pass", "duration_ms" => 405_000 },
                      { "sop" => "qa_up_smoke", "cmd" => "curl /up", "result" => "pass", "duration_ms" => 8_000 },
                      { "sop" => "qa_post_deploy", "cmd" => "bin/rails db:seed:pokemon", "result" => "pass", "duration_ms" => 14_000 }],
               now: gate_now - 9.minutes)
GateRun.open!(subject_type: "release", subject_slug: shipped_release.slug, key: "g4_ship",
              source: "seed", actor: "avi", now: gate_now - 4.minutes)
GateRun.close!(subject_type: "release", subject_slug: shipped_release.slug, key: "g4_ship",
               success: true, source: "seed", actor: "avi",
               metadata: { "seal" => "green" },
               sops: [{ "sop" => "ship_test_gate", "cmd" => "skipped — bin/rails test already green @ e2edemo at G3 (pre-QA gate, same SHA + command)", "result" => "pass" },
                      { "sop" => "deploy:mcritchie-studio", "cmd" => "git push heroku main", "result" => "pass", "duration_ms" => 95_000 },
                      { "sop" => "prod_up_smoke", "cmd" => "curl https://mcritchie.studio/up", "result" => "pass", "duration_ms" => 900 },
                      { "sop" => "prod_smoke_seal", "cmd" => "bin/prod-smoke mcritchie-studio", "result" => "pass", "duration_ms" => 41_000 }],
               now: gate_now)

active_release = Release.open!
active_release.update!(metadata: { "devops" => { "mascot" => "snorlax", "mascot_session" => "sess-active" } })
[
  ["release-stack-current-a", "Current release readiness review"],
  ["release-stack-current-b", "Current release QA verification"],
  ["release-stack-current-c", "Current release deploy confirmation"]
].each { |slug, title| release_member!(active_release, slug: slug, title: title) }
# Mid-assembly stage stamps (the tracker's time-and-boolean inputs): Tested ✓,
# Assembling live — so the deployments e2e sees an active node with its ticking
# countdown against the last-three-release average.
active_release.update_columns(created_at: 10.minutes.ago, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
active_release.stamp_stage!("testing", at: 9.minutes.ago)
active_release.stamp_stage!("assembling", at: 8.minutes.ago)

# /intelligence demo: two SHIPPED tasks that each walked the full lifecycle with
# priced/sized transitions and an actual_size at ship — so the dashboard's cycle
# time, estimate-vs-actual, tokens, cost and model-mix charts all have signal in
# the e2e env (timeline-demo alone never ships, so cycle/estimate would be empty).
[
  { slug: "intel-shipped-a", title: "Intelligence demo shipped a",
    po: "medium", dev: "large", actual: "xl",
    created: 12.days.ago, shipped: 9.days.ago,
    events: [
      { from: "designed",  to: "building",  secs: 3_600,  tin: 20_000,  tout: 30_000,  cost: "0.80", model: "claude-opus-4-8" },
      { from: "building",  to: "submitted", secs: 86_400, tin: 180_000, tout: 90_000,  cost: "6.20", model: "claude-opus-4-8" },
      { from: "submitted", to: "reviewed",  secs: 7_200,  tin: 12_000,  tout: 6_000,   cost: "0.40", model: "claude-haiku-4" },
      { from: "reviewed",  to: "assembled", secs: 3_600,  tin: 4_000,   tout: 2_000,   cost: "0.15", model: "claude-haiku-4" },
      { from: "assembled", to: "shipped",   secs: 1_800,  tin: nil,     tout: nil,     cost: nil,    model: nil }
    ] },
  { slug: "intel-shipped-b", title: "Intelligence demo shipped b",
    po: "small", dev: "medium", actual: "small",
    created: 6.days.ago, shipped: 4.days.ago,
    events: [
      { from: "designed",  to: "building",  secs: 1_800,  tin: 8_000,   tout: 12_000,  cost: "0.35", model: "claude-sonnet-4-5" },
      { from: "building",  to: "submitted", secs: 28_800, tin: 60_000,  tout: 40_000,  cost: "2.10", model: "claude-sonnet-4-5" },
      { from: "submitted", to: "reviewed",  secs: 5_400,  tin: 6_000,   tout: 3_000,   cost: "0.20", model: "claude-haiku-4" },
      { from: "reviewed",  to: "assembled", secs: 2_400,  tin: 3_000,   tout: 1_500,   cost: "0.10", model: "claude-haiku-4" },
      { from: "assembled", to: "shipped",   secs: 1_200,  tin: nil,     tout: nil,     cost: nil,    model: nil }
    ] }
].each do |spec|
  t = Task.create!(title: spec[:title], slug: spec[:slug], stage: "shipped", priority: 1,
                   po_size: spec[:po], dev_size: spec[:dev], actual_size: spec[:actual],
                   metadata: { "devops" => { "kind" => "feature", "shape" => "ui+db", "repositories" => ["mcritchie-studio"] } })
  t.task_events.delete_all
  at = spec[:created]
  spec[:events].each do |e|
    at += e[:secs].seconds
    t.task_events.create!(from_stage: e[:from], to_stage: e[:to], occurred_at: at,
                          seconds_in_from: e[:secs], tokens_in: e[:tin], tokens_out: e[:tout],
                          cost: e[:cost], model: e[:model], source: "cli", actor: "shannon")
  end
  t.update_columns(created_at: spec[:created], completed_at: spec[:shipped], updated_at: at)
end

Release::DurationCache.refresh_recent!(limit: 3)

# Testing-phases demo: one task that walked the full testing-phase lifecycle with
# durable cert checkpoints, CI test-scope evidence and a G2 review gate run, so
# /tasks/testing-phases-demo renders each of the four v2 phase chips (Build →
# Local Certification → CI → Review) with a measured duration, and the
# /intelligence "Testing phase speed" chart has signal beyond the two shipped
# demos. The operator-approval stamps stay on the task (they are real devops
# data) but no longer project as a phase — v2 dropped Operator Acceptance.
tp_anchor = 3.hours.ago
tp = Task.create!(
  title: "Testing phases demo", slug: "testing-phases-demo", stage: "reviewed", priority: 1,
  metadata: { "devops" => {
    "kind" => "feature", "shape" => "ui+db", "repositories" => ["mcritchie-studio"],
    "approval_requested_at" => (tp_anchor + 40.minutes).iso8601,
    "approval_approved_at" => (tp_anchor + 70.minutes).iso8601
  } }
)
tp.task_events.delete_all
[
  { kind: TaskEvent::TRANSITION, from: "designed",  to: "building",  at: tp_anchor,              meta: {} },
  { kind: TaskEvent::CHECKPOINT, from: "building",  to: "cert",      at: tp_anchor + 10.minutes, meta: { "status" => "started" } },
  { kind: TaskEvent::CHECKPOINT, from: "building",  to: "cert",      at: tp_anchor + 15.minutes, meta: { "status" => "completed" } },
  { kind: TaskEvent::TRANSITION, from: "building",  to: "submitted", at: tp_anchor + 20.minutes, meta: {} },
  { kind: TaskEvent::TRANSITION, from: "submitted", to: "reviewed",  at: tp_anchor + 35.minutes, meta: {} }
].each do |e|
  tp.task_events.create!(kind: e[:kind], from_stage: e[:from], to_stage: e[:to],
                         occurred_at: e[:at], seconds_in_from: nil, source: "system", metadata: e[:meta])
end

# CI evidence for the v2 CI phase (submitted handoff → checks settle): two
# test-scope AgentActions like bin/ci-scope-capture ingests, so the demo's CI
# window closes at +24m (a 4-minute handoff after the +20m submission). The
# global AtomicAction.delete_all wipe above keeps this reseed idempotent.
AgentAction.create!(session_id: "sess-tp-ci", kind: "test_scope", event_slug: "ci_lint",
                    result_slug: "pass", task_slug: tp.slug, occurred_at: tp_anchor + 23.minutes,
                    duration_ms: 90_000,
                    summary: "test scope ci_lint COMPLETED · ci · pass · bin/rubocop -f github · 1.5m")
AgentAction.create!(session_id: "sess-tp-ci", kind: "test_scope", event_slug: "ci_test",
                    result_slug: "pass", task_slug: tp.slug, occurred_at: tp_anchor + 24.minutes,
                    duration_ms: 300_000,
                    summary: "test scope ci_test COMPLETED · ci · pass · bin/rails test test:system · 5m")

# Testing-gates demo, on the same task: attempt-aware GATE verdicts so
# /tasks/testing-phases-demo also renders the "Testing gates" card — a G1 Cert
# that failed once and passed on attempt 2 (exercising the retry count), a
# passed primary review lane, and a light lane still in flight.
# Idempotent reseed: gate runs are slug-keyed and Task.delete_all skips destroy
# callbacks, so prior runs survive a wipe and would inflate the attempt numbers
# below (the spec hard-asserts "attempt 2") — clear them first, mirroring the
# task_events.delete_all above.
tp.gate_runs.delete_all
GateRun.close!(subject_type: "task", subject_slug: tp.slug, key: "g1_cert", success: false,
               sops: [{ "sop" => "full-suite", "cmd" => "bin/rails test", "result" => "fail", "duration_ms" => 412_000 }],
               now: tp_anchor + 8.minutes)
GateRun.open!(subject_type: "task", subject_slug: tp.slug, key: "g1_cert", now: tp_anchor + 10.minutes)
GateRun.close!(subject_type: "task", subject_slug: tp.slug, key: "g1_cert", success: true,
               sops: [{ "sop" => "full-suite", "cmd" => "bin/rails test", "result" => "pass", "duration_ms" => 405_000 },
                      { "sop" => "rubocop", "cmd" => "bin/rubocop", "result" => "pass", "duration_ms" => 21_000 },
                      { "sop" => "dor-check", "cmd" => "bin/dor-check #{tp.slug}", "result" => "pass" },
                      { "sop" => "ci", "result" => "pass" }],
               now: tp_anchor + 15.minutes)
GateRun.open!(subject_type: "task", subject_slug: tp.slug, key: "g2a_primary", actor: "carl",
              now: tp_anchor + 22.minutes)
GateRun.close!(subject_type: "task", subject_slug: tp.slug, key: "g2a_primary", success: true, actor: "carl",
               sops: [{ "sop" => "scout-report", "result" => "pass" }], now: tp_anchor + 33.minutes)
GateRun.open!(subject_type: "task", subject_slug: tp.slug, key: "g2b_light", actor: "shannon",
              now: tp_anchor + 22.minutes)

# Materialize every task's testing-phase projection (intel-shipped demos yield
# Build + legacy-fallback Review windows; the demo above yields all four v2
# phases). AFTER the gate runs + CI actions above — the v2 review phase anchors
# to the first G2 gate run and the CI phase settles on the captured CI actions,
# so materializing earlier would cache pre-evidence windows.
Task::TestingPhases.backfill!

# /alex/heartbeat demo: a representative agent-narrated EVENT trajectory so the
# learning heartbeat renders spans in the e2e env (capture is forward-only, so it
# is otherwise empty). Trimmed mirror of lib/tasks/atomic.rake's demo — a couple of
# closed spans, a final OPEN span (renders "…in progress"), and one pre-narration
# boot action captured with no span open (the read-only "Unlabeled" group). Mascot
# "snorlax" matches a seeded Pokémon above so the mascot resolves a real name.
hb_session = "e2e-heartbeat-0001"
hb_task = "atomic-action-capture"
hb_price = ->(tin, tout, model) { model ? (((tin * 5.0) + (tout * 25.0)) / 1_000_000.0).round(4) : 0 }
hb_base = 30.minutes.ago
hb_i = -1
hb_capture = lambda do |row|
  hb_i += 1
  AtomicAction.capture(
    session_id: hb_session, task_slug: row[:task], mascot: (row.key?(:mascot) ? row[:mascot] : "snorlax"),
    kind: row[:kind], event_slug: row[:ev], result_slug: row[:rs], input: row[:in], outcome: row[:outcome] || "ok",
    summary: row[:sm], key_method: row[:km], key_method_lang: row[:kl],
    actor: row[:actor], model: row[:model], tokens_in: row[:ti].to_i, tokens_out: row[:to].to_i,
    cost: hb_price.call(row[:ti].to_i, row[:to].to_i, row[:model]), stage: row[:stage],
    occurred_at: hb_base + (hb_i * 30).seconds
  )
end

# Pre-narration boot (no span open yet) -> Unlabeled group.
hb_capture.call(kind: "boot", actor: "harness", stage: nil, mascot: nil, in: "spin up the session runtime",
                ev: "Spin up fresh session runtime", rs: "Session identity and model resolved")

hb_spans = [
  { category: "Explore", reason: "find the capture seam", outcome: "located the model and schema seam", stage: "building",
    km: "AtomicAction.capture(session_id:, kind:, input:)", kl: "ruby",
    rows: [
      { kind: "explore", actor: "agent", task: hb_task, model: "claude-opus-4-8", ti: 9400, to: 360, in: "grep -rn AtomicEvent app/models", ev: "Explore the model and schema seam", rs: "Found the capture seam quickly", sm: "find the capture model seam", km: "grep -rn AtomicEvent app/models", kl: "bash" },
      { kind: "edit",    actor: "agent", task: hb_task, model: "claude-opus-4-8", ti: 6800, to: 2400, in: "app/views/heartbeat/_event_table.html.erb", ev: "Implement the event trajectory view", rs: "Controller view and helper written" }
    ] },
  { category: "Verify", reason: "run the unit suite", outcome: "green after a fix", stage: "building",
    rows: [
      { kind: "run-test", actor: "board", task: hb_task, outcome: "error", in: "bin/rails test test/views/heartbeat_event_table_test.rb", ev: "Run the unit test suite", rs: "One spec fails on null outcome" }
    ] },
  { category: "Workflow", reason: "certify and open the PR", outcome: nil, stage: "submitted",
    rows: [
      { kind: "open-pr",     actor: "agent", task: hb_task, model: "claude-opus-4-8", ti: 1800, to: 540, in: "gh pr create --base release", ev: "Open a pull request into release", rs: "PR opened task URL leading" },
      { kind: "review-wait", actor: "board", task: hb_task, outcome: "pending", in: "await senior QA verdict", ev: "Await senior QA review verdict", rs: "Submitted PR now in the queue" }
    ] }
]

hb_spans.each do |span|
  AtomicEvent.open_event!(session_id: hb_session, category: span[:category], reason_slug: span[:reason],
                          task_slug: span[:rows].first[:task], mascot: "snorlax", stage: span[:stage],
                          opened_at: hb_base + ((hb_i + 1) * 30).seconds)
  span[:rows].each { |row| hb_capture.call(row) }
  next if span[:outcome].nil? # leave the final span open -> "…in progress"

  AtomicEvent.close_event!(session_id: hb_session, outcome_slug: span[:outcome],
                           key_method: span[:km], key_method_lang: span[:kl],
                           closed_at: hb_base + (hb_i * 30).seconds + 5.seconds)
end

# Stage-change status badge: one kind:"transition" TaskEvent inside the Explore span's
# window (that span opened at hb_base+30s, closed at +65s) so the heartbeat status
# column badges that span with the stage its task moved TO — the "building" board pill
# + color — instead of the generic "done". The Verify span (window +90..+95s) and the
# still-open Workflow span (window +120s.. ) see no in-window transition, so they keep
# their plain done / open badges — proving the fallback path too. Backfilled so it
# never spams the /deployments board during the e2e seed.
TaskEvent.create!(task_slug: hb_task, from_stage: "designed", to_stage: "building",
                  kind: "transition", occurred_at: hb_base + 45.seconds,
                  metadata: { "backfilled" => true })

# Mascot-evolution demo: a task whose Pokémon evolves at the two pipeline gates
# (submitted → Croconaw, reviewed → Feraligatr). The task-page e2e asserts the
# timeline shows the line progressing while historical cards keep their form.
# The Totodile line deliberately avoids slugs the unit suites create! ad hoc
# (Charmander, Snorlax, Chikorita…), so leftover e2e rows can't collide there.
[[158, "totodile", ["croconaw"]],
 [159, "croconaw", ["feraligatr"]],
 [160, "feraligatr", []]].each do |dex, slug, evolution|
  Pokemon.create!(dex: dex, name: slug.capitalize, slug: slug, generation: 2,
                  base: "totodile", evolution: evolution, baby: [],
                  sprite_url: "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/#{dex}-#{slug}-sprite.png",
                  avatar_url: "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/#{dex}-#{slug}-cropped.png")
end
SessionMascot.create!(session_id: "sess-evolution-demo", mascot_slug: "totodile")
evolution_task = Task.create!(
  title: "Mascot evolution demo",
  slug: "mascot-evolution-demo",
  description: "Fixture for the mascot-evolution timeline e2e — Totodile submits as Croconaw and reviews as Feraligatr.",
  stage: "designed",
  priority: 1,
  metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio"],
                            "session_id" => "sess-evolution-demo" } }
)
evolution_task.build!
evolution_task.submit!
evolution_task.review!
evolution_task.assemble!

# ── Distillation pipeline · Test runs band + a gradeable test-run insight ──────
# A couple of release test-scope VERDICTS (kind:test_scope with a pass|fail
# result_slug) so the pipeline's "Test runs" band renders, plus a banked Alex
# grade on the passing one so it also surfaces as a Column-2 insight carrying an
# ACTION Confirm button (the confirm-of-action path). The scope keys resolve to
# phase/tier/host via config/devops_test_suites.yml at render.
test_run_pass = AgentAction.create!(
  session_id: "sess-test-runs", kind: "test_scope", event_slug: "ship_test_gate",
  result_slug: "pass", task_slug: hb_task, occurred_at: Time.current, duration_ms: 12_300,
  summary: "test scope ship_test_gate COMPLETED · mcritchie-studio · pass · " \
           "141 runs, 320 assertions, 0 failures, 0 errors · 12.3s · bin/rails test"
)
AgentAction.create!(
  session_id: "sess-test-runs", kind: "test_scope", event_slug: "qa_up_smoke",
  result_slug: "fail", occurred_at: Time.current, duration_ms: 4_200,
  summary: "test scope qa_up_smoke FAILED · qa · fail · http 503 · 4.2s · /up poll"
)
ActionGrade.create!(agent_action: test_run_pass, grader: "alex", disposition: "good",
                    slug: "ship gate stayed green").bank!

puts "Seeded: #{User.count} users, #{Agent.count} agents, #{Task.count} tasks, #{Activity.count} activities, #{Coach.count} coaches, #{Release.count} releases, #{AtomicAction.count} atomic actions, #{AtomicEvent.count} atomic events"
