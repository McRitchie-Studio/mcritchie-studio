# Evolution families used for subagent mascot allocation, derived from the
# Pokémon reference columns (base + evolution) so one source of truth covers
# both generations — the hardcoded Gen 1 groups this replaced predated those
# columns. A family is the base form plus everything reachable through the
# evolution lists, in walk order (base first). Babies stay out: they are
# reference data only and are never assigned as mascots.
class PokemonEvolutionTree
  # The family for a slug, as an ordered slug array including the input's whole
  # line (asking from Charizard still returns the Charmander family). Unknown
  # slugs collapse to a single-member family so callers never get a surprise [].
  def self.for(slug)
    key = slug.to_s.strip
    return [] if key.empty?

    pokemon = Pokemon.find_by(slug: key)
    return [key] unless pokemon

    family_of(pokemon).presence || [key]
  end

  def self.family_of(pokemon)
    root = pokemon.base_form? ? pokemon : Pokemon.find_by(slug: pokemon.base) || pokemon
    ordered = []
    frontier = [root]
    until frontier.empty?
      ordered.concat(frontier.map(&:slug))
      next_slugs = frontier.flat_map { |member| Array(member.evolution) }.uniq - ordered
      frontier = Pokemon.where(slug: next_slugs).to_a
    end
    ordered
  end
end
