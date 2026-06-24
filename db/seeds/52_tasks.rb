tasks_data = [
  { title: "Review agent communication protocol",  stage: "designed",  priority: 0, agent_slug: "alex",         description: "Audit and improve inter-agent messaging patterns." },
  { title: "Set up nightly sync job",              stage: "designed",  priority: 0, agent_slug: "mason",        description: "Configure cron job for nightly data sync across all agent databases." },
  { title: "Generate player prop lines",           stage: "building",  priority: 1, agent_slug: "turf-monster", description: "Calculate over/under lines for 67 seeded players based on historical data." },
  { title: "Review Turf Monster Tailwind PR",      stage: "submitted", priority: 1, agent_slug: "avi",          description: "Inspect the Tailwind PR metadata, diff, tests, and merge safety." },
  { title: "QA Turf Monster contest flow",         stage: "reviewed",  priority: 2, agent_slug: "avi",          description: "Approved after contest create and entry smoke checks — waiting for a release." },
  { title: "Prepare production release train",      stage: "assembled", priority: 2, agent_slug: "alex",         description: "Merged into the current release branch; riding the train to QA." },
  { title: "Deploy Turf Monster v2.1",             stage: "shipped",   priority: 2, agent_slug: "mason",        description: "Shipped with long-press button and cart improvements." },
  { title: "Archive stale Q1 tasks",               stage: "archived",  priority: 0, agent_slug: nil,            description: "Clean up completed tasks from Q1 2026." },
  { title: "Fix mobile cart persistence bug",      stage: "blocked",   priority: 2, agent_slug: "turf-monster", description: "Cart picks disappear on mobile Safari after backgrounding the app.", error_message: "localStorage quota exceeded on iOS Safari private browsing", block_kind: "environment" }
]

tasks_data.each do |data|
  task = Task.find_or_create_by!(title: data[:title]) do |t|
    t.description = data[:description]
    t.stage = data[:stage]
    t.priority = data[:priority]
    t.agent_slug = data[:agent_slug]
    t.error_message = data[:error_message]
    t.metadata = { "devops" => { "block_kind" => data[:block_kind] } } if data[:block_kind]

    case data[:stage]
    when "building"  then t.started_at = 3.hours.ago
    when "submitted" then t.started_at = 1.day.ago;  t.submitted_at = 2.hours.ago
    when "reviewed"  then t.started_at = 2.days.ago; t.submitted_at = 1.day.ago; t.reviewed_at = 4.hours.ago
    when "assembled" then t.started_at = 3.days.ago; t.submitted_at = 2.days.ago; t.reviewed_at = 1.day.ago; t.assembled_at = 2.hours.ago
    when "shipped"   then t.started_at = 4.days.ago; t.completed_at = 1.day.ago
    when "blocked"   then t.started_at = 1.day.ago;  t.blocked_at = 6.hours.ago; t.blocked_from = "building"
    when "archived"  then t.archived_at = 1.week.ago
    end
  end
  puts "Task: #{task.title} (#{task.stage})"
end

# --- Board visual-state enrichment ---------------------------------------------
# A few of the seeded cards carry the devops metadata, stage crew, and an activity
# note that the board card actually renders, so the dashboard's gem / under-slug
# crew / qa-feedback states show up in dev WITHOUT hand-seeding. Idempotent: the
# metadata, events, and note are each written at most once (no churn on re-seed,
# since seeds run on every deploy).
def crew_event(task, **attrs)
  task.task_events.create!(attrs)
end

# 1) GEM release + Local/PR links → footer 💎 and the Local/PR footer links.
if (gem = Task.find_by(title: "Review Turf Monster Tailwind PR")) &&
   gem.metadata.dig("devops", "shape") != "library"
  gem.update!(metadata: gem.metadata.deep_merge(
    "devops" => {
      "shape" => "library", "repositories" => ["studio-engine"],
      "local_url" => "http://localhost:3000/tasks",
      "pr_url" => "https://github.com/amcritchie/studio-engine/pull/1"
    }
  ))
end

# 2) UNDER-SLUG CREW: a building card with two distinct build actors → the lane grid.
# Guard on ACTORED events (a Task auto-stamps a nil-actor genesis event on create),
# so this adds the crew once and re-seeds clean.
if (crew = Task.find_by(title: "Generate player prop lines")) &&
   crew.task_events.where.not(actor: nil).none?
  crew_event(crew, to_stage: "designed", occurred_at: 2.days.ago, actor: "shannon")
  crew_event(crew, from_stage: "designed", to_stage: "building",
                   occurred_at: 1.day.ago, seconds_in_from: 86_400, actor: "carl")
end

# 3) FULL DEPLOY CREW + gem on a shipped card → the whole journey + footer 💎.
if (shipped = Task.find_by(title: "Deploy Turf Monster v2.1")) &&
   shipped.task_events.where.not(actor: nil).none?
  shipped.update!(metadata: shipped.metadata.deep_merge("devops" => { "shape" => "library" })) \
    if shipped.metadata.dig("devops", "shape") != "library"
  crew_event(shipped, to_stage: "designed", occurred_at: 5.days.ago, actor: "shannon")
  crew_event(shipped, from_stage: "designed", to_stage: "building",
                      occurred_at: 4.days.ago, seconds_in_from: 86_400, actor: "carl")
  crew_event(shipped, from_stage: "building", to_stage: "submitted",
                      occurred_at: 3.days.ago, seconds_in_from: 86_400, actor: "jasper")
  crew_event(shipped, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 2.days.ago, seconds_in_from: 86_400,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "heavy" },
                                                  { "slug" => "carl", "weight" => "light" }] })
  crew_event(shipped, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 1.day.ago, seconds_in_from: 43_200, actor: "steffon")
  crew_event(shipped, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 6.hours.ago, seconds_in_from: 21_600, actor: "avi")
end

# 4) QA-FEEDBACK note → the activity box (white "QA FEEDBACK" label inside it).
if (reviewed = Task.find_by(title: "QA Turf Monster contest flow")) &&
   Activity.where(task_slug: reviewed.slug, activity_type: "qa_feedback").none?
  Activity.create!(task_slug: reviewed.slug, agent_slug: "steffon", activity_type: "qa_feedback",
                   description: "QA-deployed on release; awaiting the operator prod-ship gate before shipping.")
end
puts "Board visual-state enrichment: gem + under-slug crew + qa-feedback applied"
