tasks_data = [
  { title: "Review agent communication protocol",  stage: "designed",  priority: 0, agent_slug: "alex",         description: "Audit and improve inter-agent messaging patterns." },
  { title: "Set up nightly sync job",              stage: "designed",  priority: 0, agent_slug: "mason",        description: "Configure cron job for nightly data sync across all agent databases." },
  { title: "Generate player prop lines",           stage: "building",  priority: 1, agent_slug: "turf-monster", description: "Calculate over/under lines for 67 seeded players based on historical data." },
  { title: "Review Turf Monster Tailwind PR",      stage: "submitted", priority: 1, agent_slug: "avi",          description: "Inspect the Tailwind PR metadata, diff, tests, and merge safety." },
  { title: "QA Turf Monster contest flow",         stage: "reviewed",  priority: 2, agent_slug: "avi",          description: "Approved after contest create and entry smoke checks — waiting for a release." },
  { title: "Prepare production release train",      stage: "assembled", priority: 2, agent_slug: "alex",         description: "Merged into the current release branch; riding the train to QA." },
  { title: "Deploy Turf Monster v2.1",             stage: "shipped",   priority: 2, agent_slug: "mason",        description: "Shipped with long-press button and cart improvements." },
  { title: "Archive stale Q1 tasks",               stage: "archived",  priority: 0, agent_slug: nil,            description: "Clean up completed tasks from Q1 2026." },
  { title: "Fix cart persistence bug on mobile",   stage: "blocked",   priority: 2, agent_slug: "turf-monster", description: "Cart picks disappear on mobile Safari after backgrounding the app.", error_message: "localStorage quota exceeded on iOS Safari private browsing", block_kind: "environment" }
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
