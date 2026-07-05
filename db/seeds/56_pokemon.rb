# The Gen 1–2 Pokémon (dex 1–251) — reference data backing the per-task mascot
# draw (Task#assign_mascot) and reusable elsewhere. DB-only: image bytes are
# mirrored into S3 separately by `rake pokemon:upload_images` (lib/tasks/pokemon.rake),
# the same identity-vs-bytes split as the coach/athlete headshots (32_headshot_links).
#
# Idempotent — upserts by dex, so re-seeding refreshes fields without duplicating.

puts "\n--- Pokémon (Gen 1–2) ---"

POKEMON_FIELDS = %w[
  name slug types hp attack defense special_attack special_defense speed
  generation base evolution baby
  avatar_url avatar_fallback_url sprite_url
  shiny_avatar_url shiny_avatar_fallback_url shiny_sprite_url
].freeze

JSON.parse(File.read(Rails.root.join("db/seeds/data/pokemon.json"))).each do |row|
  Pokemon.find_or_initialize_by(dex: row["dex"]).update!(row.slice(*POKEMON_FIELDS))
end

puts "  Pokémon: #{Pokemon.count}"
