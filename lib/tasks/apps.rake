namespace :apps do
  desc "Seed the managed-app registry rows (idempotent; runs post-deploy)"
  task seed: :environment do
    # Heroku's release phase runs db:migrate but NOT db:seed, so the App rows —
    # the status-line color/emoji source bin/statusline reads — are seeded here on
    # deploy (devops.post_deploy_cmd). Idempotent: the seed upserts by slug.
    load Rails.root.join("db/seeds/00_apps.rb")
  end
end

namespace :agents do
  desc "Seed the agent roster, status-line identity and skill assignments (idempotent; runs post-deploy)"
  task seed: :environment do
    # Same release-phase reason as apps:seed — re-runs the roster upsert so each
    # soul's status-line emoji + color (Agent#emoji / #status_color) lands on prod.
    load Rails.root.join("db/seeds/02_agents.rb")
    # Then the skills, which key on the roster's slugs (SkillAssignment belongs_to
    # :agent), so they ride the same run. Without it no skill or assignment ever
    # reached a deployed database: prod held none on 2026-10-27, so the Mason/Alex
    # swap in 03_skills.rb (rename-loose-ends) never landed. The seed syncs each
    # soul it lists to exactly its list.
    load Rails.root.join("db/seeds/03_skills.rb")
  end

  # The orchestrator's skill belongs to the orchestrator. Exits non-zero naming the
  # drift, so a post_deploy_cmd of `agents:seed agents:verify_skills` proves the
  # seed landed rather than that a process exited 0.
  desc "Fail unless mason holds the orchestration skill and alex holds the persona's brand skills, not it"
  task verify_skills: :environment do
    orchestration = "task-orchestration"
    held = ->(slug) { SkillAssignment.where(agent_slug: slug).pluck(:skill_slug).sort }
    mason = held.call("mason")
    alex = held.call("alex")
    drift = []
    drift << "mason lacks #{orchestration} (holds #{mason.inspect})" unless mason.include?(orchestration)
    drift << "alex still holds #{orchestration} (holds #{alex.inspect})" if alex.include?(orchestration)
    drift << "alex lacks brand-voice (holds #{alex.inspect})" unless alex.include?("brand-voice")
    abort("agents:verify_skills: #{drift.join('; ')}") if drift.any?

    puts "agents:verify_skills: mason #{mason.inspect}; alex #{alex.inspect}"
  end
end
