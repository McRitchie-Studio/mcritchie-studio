# Pokémon type colors — the FIRST use of the shared Studio::Enumeral table. Each
# of the 18 canonical types is one enumeral in the "pokemon_type" category,
# carrying the type's display color (hex). The /pokemon list + grid color their
# type badges from these (Pokemon.type_colors → Studio::Enumeral.color_map).
#
# Idempotent — upserts by (category, key), so re-seeding refreshes the label/
# color/position without duplicating. Runs on deploy via `rake enumerals:seed`
# (devops.post_deploy_cmd) since Heroku's release phase runs db:migrate, not
# db:seed.

puts "\n--- Pokémon type colors (enumerals) ---"

# Canonical type → display color + emoji, in National-Dex type order. Position
# is the array index so a UI can list them in this familiar order. The emoji is
# decorative, so it rides in `metadata` rather than its own column.
POKEMON_TYPE_COLORS = [
  ["normal",   "Normal",   "#A8A77A", "⚪"],
  ["fire",     "Fire",     "#EE8130", "🔥"],
  ["water",    "Water",    "#6390F0", "💧"],
  ["electric", "Electric", "#F7D02C", "⚡"],
  ["grass",    "Grass",    "#7AC74C", "🍃"],
  ["ice",      "Ice",      "#96D9D6", "❄️"],
  ["fighting", "Fighting", "#C22E28", "🥊"],
  ["poison",   "Poison",   "#A33EA1", "☠️"],
  ["ground",   "Ground",   "#E2BF65", "🏜️"],
  ["flying",   "Flying",   "#A98FF3", "🦅"],
  ["psychic",  "Psychic",  "#F95587", "🔮"],
  ["bug",      "Bug",      "#A6B91A", "🐛"],
  ["rock",     "Rock",     "#B6A136", "🪨"],
  ["ghost",    "Ghost",    "#735797", "👻"],
  ["dragon",   "Dragon",   "#6F35FC", "🐉"],
  ["dark",     "Dark",     "#705746", "🌑"],
  ["steel",    "Steel",    "#B7B7CE", "⚙️"],
  ["fairy",    "Fairy",    "#D685AD", "🧚"]
].freeze

# Rank the types by how common they are in the seeded list (the original 151),
# most common → least common, in steps of 100 so a value can be inserted between
# two ranks later without renumbering. Counts come from the SAME committed JSON
# the Pokémon seed loads; ties break on the canonical type order (position), and
# a type absent from the 151 (e.g. Dark) ranks last.
type_position = POKEMON_TYPE_COLORS.each_with_index.to_h { |(key, *), i| [key, i] }
counts = Hash.new(0)
JSON.parse(File.read(Rails.root.join("db/seeds/data/pokemon.json"))).each do |row|
  Array(row["types"]).each { |type| counts[type] += 1 }
end
rank_by_key = type_position.keys
                           .sort_by { |key| [-counts[key], type_position[key]] }
                           .each_with_index
                           .to_h { |key, i| [key, (i + 1) * 100] }

POKEMON_TYPE_COLORS.each do |key, label, color, emoji|
  Studio::Enumeral.find_or_initialize_by(category: "pokemon_type", key: key)
                  .update!(label: label, color: color,
                           position: type_position[key], rank: rank_by_key[key],
                           metadata: { "emoji" => emoji })
end

puts "  pokemon_type enumerals: #{Studio::Enumeral.in_category('pokemon_type').count} " \
     "(most common: #{Studio::Enumeral.in_category('pokemon_type').by_rank.first&.key})"
