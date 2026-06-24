namespace :enumerals do
  desc "Seed the studio_enumerals reference rows (idempotent; runs post-deploy)"
  task seed: :environment do
    # Heroku's release phase runs db:migrate but NOT db:seed, so the enumeral
    # rows are seeded here on deploy (devops.post_deploy_cmd). Idempotent: the
    # seed upserts by (category, key).
    load Rails.root.join("db/seeds/57_pokemon_type_colors.rb")
  end
end
