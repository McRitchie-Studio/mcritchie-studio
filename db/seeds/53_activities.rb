activities_data = [
  { agent_slug: "mack",         activity_type: "task_completed", description: "Completed scraping World Cup 2026 group stage odds" },
  { agent_slug: "mason",        activity_type: "deployment",     description: "Deployed Turf Monster v2.1 to production" },
  { agent_slug: "turf-monster", activity_type: "task_started",   description: "Started generating player prop lines" },
  { agent_slug: "xan",          activity_type: "task_assigned",  description: "Assigned nightly sync setup to Mason" },
  { agent_slug: "xan",          activity_type: "system_check",   description: "All agents healthy, 4/4 active" },
  { agent_slug: "mack",         activity_type: "data_sync",      description: "Synced 48 team records and 72 game records" }
]

activities_data.each do |data|
  Activity.create!(data) unless Activity.exists?(description: data[:description])
end
puts "Activities created"
