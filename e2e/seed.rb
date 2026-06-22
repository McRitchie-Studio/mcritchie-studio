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

puts "Seeded: #{User.count} users, #{Agent.count} agents, #{Task.count} tasks, #{Activity.count} activities, #{Coach.count} coaches"
