# Cache each Pokémon's primary (identifying) type onto pokemons.primary_type so
# color lookups read a column instead of re-ranking the least-common type on every
# call. Runs AFTER 56_pokemon.rb (the rows) and 57_pokemon_type_colors.rb (the type
# ranks) — db/seeds.rb loads files in numeric-prefix order. Idempotent and
# re-runnable via Pokemon.assign_primary_types! (only changed rows are written), so
# re-run it after the roster grows beyond gen-1.

puts "\n--- Pokémon primary types ---"

updated = Pokemon.assign_primary_types!
cached  = Pokemon.where.not(primary_type: nil).count
puts "  primary_type: #{updated} updated (#{cached}/#{Pokemon.count} cached)"
