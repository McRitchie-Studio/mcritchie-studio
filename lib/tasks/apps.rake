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
  desc "Seed the agent roster + status-line identity (idempotent; runs post-deploy)"
  task seed: :environment do
    # Same release-phase reason as apps:seed — re-runs the roster upsert so each
    # soul's status-line emoji + color (Agent#emoji / #status_color) lands on prod.
    load Rails.root.join("db/seeds/02_agents.rb")
  end
end
