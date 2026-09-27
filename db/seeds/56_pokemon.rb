# The Gen 1–2 Pokémon (dex 1–251) — reference data backing the per-task mascot
# draw (Task#assign_mascot) and reusable elsewhere. DB-only: image bytes are
# mirrored into S3 separately by `rake pokemon:upload_images` (lib/tasks/pokemon.rake),
# the same identity-vs-bytes split as the coach/athlete headshots (32_headshot_links).
#
# Idempotent — upserts by SLUG, so re-seeding refreshes fields without duplicating.
# (By slug, not dex: the nidoran gender-family row shares dex 29 with Nidoran♀.)

puts "\n--- Pokémon (Gen 1–2) ---"

POKEMON_FIELDS = %w[
  name slug types hp attack defense special_attack special_defense speed
  generation base evolution baby
  avatar_url avatar_fallback_url sprite_url
  shiny_avatar_url shiny_avatar_fallback_url shiny_sprite_url
  gender_rate has_gender_differences female_sprite_url shiny_female_sprite_url
  gender_forms evolution_genders
].freeze

JSON.parse(File.read(Rails.root.join("db/seeds/data/pokemon.json"))).each do |row|
  # Only family / gated rows carry gender_forms / evolution_genders in the JSON;
  # default the rest to {} so a re-seed also clears a rule the data dropped.
  attrs = { "gender_forms" => {}, "evolution_genders" => {} }.merge(row.slice("dex", *POKEMON_FIELDS))
  Pokemon.find_or_initialize_by(slug: row["slug"]).update!(attrs)
end

puts "  Pokémon: #{Pokemon.count}"
