# Seed test database for Playwright smoke tests.
# Run with: RAILS_ENV=test bin/rails runner e2e/seed.rb
#
# Idempotent — clears and recreates all test data.

puts "Seeding test database for Playwright..."

# Clear in dependency order
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

# Shipped first (terminal) so the active release below satisfies the singleton.
shipped_release = Release.open!
shipped_release.update!(metadata: { "devops" => { "mascot" => "dragonite", "mascot_session" => "sess-ship" } })
shipped_release.ship!
shipped_release.update_columns(created_at: 18.minutes.ago, shipped_at: Time.current)

active_release = Release.open!
active_release.update!(metadata: { "devops" => { "mascot" => "snorlax", "mascot_session" => "sess-active" } })

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

puts "Seeded: #{User.count} users, #{Agent.count} agents, #{Task.count} tasks, #{Activity.count} activities, #{Coach.count} coaches, #{Release.count} releases"
