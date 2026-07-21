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
GithubWorkflowRun.delete_all # cached Actions runs for the /deployments panel — reseeded below
CiCheckJob.delete_all # per-check LIVE CI progress rows (workflow_job) — reseeded below
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
# A block is no longer a STAGE — it is an attribute of a `building` task (blocked_at
# + blocked_from + blocked_by + block_kind), per the blocked-as-building collapse.
# Seeding stage: "blocked" now fails validation and takes the whole e2e run down with
# it, which no CI lane catches because there is no Playwright job.
Task.create!(
  title: "Sidebar back-navigation production repro",
  slug: "task-ea8541e4b5b6",
  description: "Fixture for the production sidebar back-navigation regression.",
  stage: "building",
  priority: 1,
  agent_slug: "alex",
  started_at: 1.day.ago,
  blocked_at: 6.hours.ago,
  blocked_from: "submitted",
  blocked_by: "avi",
  block_kind: "rework"
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
# --- The claim chip: liveness and progress, never conflated -------------------
# Two BUILDING desks, both holding a LIVE claim (a terminal is painting). They
# differ only in what they have PRODUCED, which is the whole point of the chip:
#
#   quiet    — heartbeating for hours with no durable artifact (the 2026-07-13 lie)
#   working  — a cert gate open right now (a healthy long build, never flagged)
#
# The lease expiry is seeded FAR in the future on purpose. A real lease carries a
# 120s TTL renewed by bin/statusline; a fixture has no statusline, so a real TTL
# would lapse between `seed` and the spec run and the chip would vanish (flake).
def e2e_claim(expires_at: 1.day.from_now)
  {
    "kind" => "feature", "repositories" => ["mcritchie-studio"],
    "claimed_session" => "e2e-session", "claim_nonce" => "e2e-instance",
    "claim_expires_at" => expires_at.utc.iso8601
  }
end

quiet_claim_task = Task.create!(
  title: "Quiet claim chip demo",
  slug: "e2e-quiet-claim-demo",
  description: "A live claim that has landed nothing in hours — held, but not progressing.",
  stage: "building", priority: 1, agent_slug: "carl",
  metadata: { "devops" => e2e_claim }
)
# Its only durable artifact sits past the derived quiet threshold — stated relative
# to the threshold so the fixture keeps demonstrating quiet if the corpus is
# re-measured. to_stage carries the checkpoint's NAME, exactly as the app writes it.
quiet_silence = ClaimLease::PROGRESS_QUIET_SECONDS + 30.minutes
TaskEvent.where(task_slug: quiet_claim_task.slug).update_all(occurred_at: (quiet_silence + 1.hour).ago)
TaskEvent.create!(task_slug: quiet_claim_task.slug, kind: TaskEvent::CHECKPOINT,
                  from_stage: "building", to_stage: "cert", occurred_at: quiet_silence.ago,
                  metadata: { "status" => "started" })

working_claim_task = Task.create!(
  title: "Working claim chip demo",
  slug: "e2e-working-claim-demo",
  description: "A live claim mid-cert — a long build that must never be flagged.",
  stage: "building", priority: 1, agent_slug: "carl",
  metadata: { "devops" => e2e_claim }
)
TaskEvent.where(task_slug: working_claim_task.slug).update_all(occurred_at: 6.hours.ago)
# An OPEN gate: the cert is running right now. This is the evidence that keeps a
# slow-but-healthy build off the quiet list, however long it stays silent.
GateRun.create!(subject_type: "task", subject_slug: working_claim_task.slug, key: "g1_cert",
                attempt: 1, started_at: 3.minutes.ago,
                created_at: 3.minutes.ago, updated_at: 3.minutes.ago)

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
# Shipped 2 minutes ago, NOT Time.current: the seeded Last Release must sit
# outside ANY fresh-deploy glow window (even the widened e2e one — playwright.
# config.js's FRESH_DEPLOY_WINDOW_MS), so no spec ever loads a board where
# Dragonite is still glowing. Only recency moves; every duration the tracker
# and average assertions read is computed relative to this stamp.
stamp_tracker_stage_history!(shipped_release, shipped_at: 2.minutes.ago)
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

# /deployments/all pagination fixture: 26 ancient shipped releases push the table
# past one page — with the 4 releases above, page 1 fills its 25 release rows + the
# 2 pinned running-average rows, and page 2 holds the 5 oldest (rel-e2e-page-01
# among them). Seeded HERE, not inside release_duration_dashboard.spec.js: that
# spec used to boot `bin/rails runner` synchronously inside its own 30s test clock
# (17-26s of it — the shard's top flake, run 29707557195). Dated 2020, far outside
# the recent window, so they never enter Release::DurationCache's recent-3 average
# (refreshed below) or the /deployments duration-card numbers other specs assert.
pagination_base_time = Time.zone.parse("2020-01-01 12:00:00")
26.times do |index|
  page_release = Release.create!(slug: "rel-e2e-page-#{format('%02d', index + 1)}", branch: "release", state: "shipped")
  page_release.update_columns( # rubocop:disable Rails/SkipsModelValidations
    created_at: pagination_base_time + index.minutes,
    shipped_at: pagination_base_time + index.minutes,
    updated_at: pagination_base_time + index.minutes
  )
end

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

# Model-pricing demo: two REAL production sessions replayed verbatim (a pokedex
# feature run on claude-opus-4-8, a testing-gates run on claude-fable-5) so
# /admin/model_pricing shows a genuine last-session summary + activity feed per
# model, and the rate sliders move real, non-zero totals. Rows captured from prod
# agent_activities (model + tokens + cache + cost); opened_at re-anchored to now
# so each is the most recent session for its model. AgentActivity is cleared by
# AtomicEvent.delete_all above (the alias), so this reseeds cleanly.
require "csv"
model_pricing_bases = {
  "4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c" => 90.minutes.ago, # opus-4-8 · pokedex feature
  "ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca" => 40.minutes.ago  # fable-5 · testing gates
}
model_pricing_rows = <<~CSV
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,0,Explore,scope newest-unique pokedex feature,claude-opus-4-8,276425,61573,2478225,4.4769
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,1,Workflow,create task + worktree for pokedex feature,claude-opus-4-8,12077,6277,1065869,0.7653
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,2,Edit,implement newest first-seen read model,claude-opus-4-8,111512,99085,5437665,5.8910
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,3,Verify,run focused pokedex tests,claude-opus-4-8,54601,46034,8006367,5.4942
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,4,Clarify,await operator visual approval,claude-opus-4-8,8751,3603,1036550,0.6630
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,5,Version,"commit, certify, dor-check, PR",claude-opus-4-8,541668,67639,6219598,8.1855
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,6,Verify,re-cert in clean env,claude-opus-4-8,4098,673,606215,0.3425
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,7,Version,push branch + open PR into release,claude-opus-4-8,47282,37387,6743170,4.6007
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,8,Explore,map token/cost capture pipeline for accuracy fix,claude-opus-4-8,56359,90638,5597535,5.4169
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,9,Plan,align fix scope with operator,claude-opus-4-8,92169,51313,7013146,5.3649
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,10,Edit,build UsagePricing module + delegate both paths,claude-opus-4-8,250613,194509,43323316,28.0886
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,11,Version,"commit, cert, dor-check, PR",claude-opus-4-8,76005,64122,30216226,17.1849
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,12,Explore,enumerate all devops testing stages from config,claude-opus-4-8,74769,26227,5882463,4.0640
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,14,Edit,cap parallel test workers in full-suite-check,claude-opus-4-8,305786,298467,77261117,49.1313
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,15,Explore,diagnose pg fork-crash blocking all local certs,claude-opus-4-8,62361,60450,7706496,5.9861
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,16,Workflow,pivot to Task B observability off clean release,claude-opus-4-8,24009,22614,10524504,6.0663
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,17,Explore,map projection + TaskEvent + approval + timeline for phase observability,claude-opus-4-8,2419915,542652,126943108,100.8621
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,18,Workflow,deploy-with-task: ship Task B to prod,claude-opus-4-8,6957,8172,683925,0.6158
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,19,Explore,orient on PR #457 diff,claude-opus-4-8,12976,13952,921168,0.9391
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,20,Verify,verify fix commit 977c77d5,claude-opus-4-8,21426,8554,2308808,1.5824
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,21,Workflow,sweep Task B onto release + QA,claude-opus-4-8,8595,7773,889500,0.7231
  4c4fb1ab-70e1-4c6b-8e58-e691e1e9cd5c,22,Explore,Read qa-release SOP before sweep,claude-opus-4-8,6124,840,598468,0.3815
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,0,Plan,orient: testing gates redesign,claude-fable-5,418195,104127,2347180,15.6379
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,1,Workflow,create gate-runs production task,claude-fable-5,44876,17460,2240863,4.0053
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,2,Explore,read producer + model idioms,claude-fable-5,124652,36217,2991705,7.2901
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,3,Edit,gate_runs migration + GateRun model,claude-fable-5,33764,24141,3886264,5.7656
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,4,Edit,wire G1 producers into cert + dor scripts,claude-fable-5,115525,75949,24898710,30.9782
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,5,Verify,rubocop + record checks + cert,claude-fable-5,36046,28538,13077242,15.2177
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,6,Workflow,"full-cycle: read SOP, run cycle",claude-fable-5,40695,16131,4898077,6.4374
  ebb5f0a0-76ce-484c-b8c7-443b9b8bd9ca,7,Explore,orient: read pr-review SOP,claude-fable-5,1740,267,294534,0.3427
CSV
CSV.parse(model_pricing_rows.strip, headers: false).each do |session_id, seq, category, reason, model, tin, tout, cread, cost|
  opened = model_pricing_bases.fetch(session_id) + (seq.to_i * 30).seconds
  AgentActivity.create!(
    session_id: session_id, seq: seq.to_i, category: category, reason_slug: reason, model: model,
    tokens_in: tin.to_i, tokens_out: tout.to_i, cache_read_tokens: cread.to_i, cost: cost.to_d,
    opened_at: opened, closed_at: opened + 20.seconds
  )
end

# GitHub Actions panel on /deployments: a passed CI run so the panel renders a
# normal status-pilled row on the board.
GithubWorkflowRun.create!(
  repo: "mcritchie/mcritchie-studio", run_id: 5_000_001, status: "completed", conclusion: "success",
  workflow_name: "CI", head_sha: "9f2c1b7ad4e5c60f1e2d3a4b5c6d7e8f90123456", head_branch: "release",
  html_url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/5000001", run_started_at: 20.minutes.ago
)

# CI progress bars (feature: visual-ci-progress-bars): a submitted task whose PR has
# a live GitHub CI run, plus a CI run on the release-branch tip, so the board e2e can
# assert the task-card "X / Y checks" meter and the Next Release G3 bar. Ci::ProgressReader
# resolves the SHA from these rows (owner amcritchie, the reader's DEFAULT_OWNER — the
# panel rows above use a legacy owner and are repo-scoped away), then folds the counts
# from CI_PROGRESS_FIXTURES (playwright webServer env) keyed by these SHAs — no network.
# run_started_at is OLDER than the panel runs above so latest_per_workflow (global, one
# row per workflow_name) still shows those on the /deployments Actions panel.
Task.create!(
  slug: "e2e-ci-progress-demo", title: "E2E CI progress demo", stage: "submitted", priority: 1,
  agent_slug: "shannon",
  metadata: { "devops" => {
    "branch" => "feat/ci-progress-e2e",
    "repositories" => ["mcritchie-studio"],
    "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/900"
  } }
)
GithubWorkflowRun.create!(
  repo: "amcritchie/mcritchie-studio", run_id: 5_000_101, status: "in_progress",
  workflow_name: "CI", head_sha: "e2e-task-sha", head_branch: "feat/ci-progress-e2e",
  html_url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/5000101", run_started_at: 30.minutes.ago
)
GithubWorkflowRun.create!(
  repo: "amcritchie/mcritchie-studio", run_id: 5_000_102, status: "completed", conclusion: "success",
  workflow_name: "CI", head_sha: "e2e-rel-sha", head_branch: "release",
  html_url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/5000102", run_started_at: 30.minutes.ago
)

# LIVE CI progress (feature: live-ci-progress-updates): a submitted task whose PR
# CI is recorded per-check as CiCheckJob rows — the workflow_job webhook path, NOT
# CI_PROGRESS_FIXTURES. Its SHA is deliberately ABSENT from the playwright fixture
# map, so a bar here can come ONLY from these live rows (5 of 8 passed) — the board
# e2e proves Ci::ProgressReader folds ingested jobs, and the stable #ci-progress
# slot is present so a real workflow_job push can morph just this bar with no reload.
Task.create!(
  slug: "e2e-live-ci-progress-demo", title: "E2E live CI progress demo", stage: "submitted", priority: 1,
  agent_slug: "shannon",
  metadata: { "devops" => {
    "branch" => "feat/ci-progress-live-e2e",
    "repositories" => ["mcritchie-studio"],
    "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/901"
  } }
)
GithubWorkflowRun.create!(
  repo: "amcritchie/mcritchie-studio", run_id: 5_000_103, status: "in_progress",
  workflow_name: "CI", head_sha: "e2e-live-task-sha", head_branch: "feat/ci-progress-live-e2e",
  html_url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/5000103", run_started_at: 25.minutes.ago
)
e2e_live_job_id = 5_100_000
5.times do |i|
  CiCheckJob.create!(repo: "amcritchie/mcritchie-studio", job_id: e2e_live_job_id + i, run_id: 5_000_103,
                     head_sha: "e2e-live-task-sha", head_branch: "feat/ci-progress-live-e2e",
                     workflow_name: "CI", name: "check-#{i}", status: "completed", conclusion: "success")
end
3.times do |i|
  CiCheckJob.create!(repo: "amcritchie/mcritchie-studio", job_id: e2e_live_job_id + 5 + i, run_id: 5_000_103,
                     head_sha: "e2e-live-task-sha", head_branch: "feat/ci-progress-live-e2e",
                     workflow_name: "CI", name: "pending-#{i}", status: "in_progress")
end

puts "Seeded: #{User.count} users, #{Agent.count} agents, #{Task.count} tasks, #{Activity.count} activities, #{Coach.count} coaches, #{Release.count} releases, #{AtomicAction.count} atomic actions, #{AtomicEvent.count} atomic events, #{GithubWorkflowRun.count} github runs"
