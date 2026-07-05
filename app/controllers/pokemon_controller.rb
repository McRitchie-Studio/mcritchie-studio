# Read-only inspector for the seeded Pokémon reference data — a quick window onto
# the shape of the rows (dex, name, types, base stats, avatars). Public-read like
# the board pages; no mutations.
class PokemonController < ApplicationController
  skip_before_action :require_authentication

  def index
    @pokemon = Pokemon.by_dex.to_a
    # One query for every type's enumeral (color + emoji); the badges read it
    # from this map so the list/grid don't query per cell. {} when the enumerals
    # aren't seeded yet.
    @type_enumerals = Pokemon.type_enumerals
    # Slug-keyed reuse of the same loaded rows, so each grid card's evolution
    # circles resolve without a query per card.
    @pokemon_by_slug = @pokemon.index_by(&:slug)
  end
end
