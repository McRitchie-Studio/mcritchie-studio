# Read-only inspector for the seeded Pokémon reference data — a quick window onto
# the shape of the rows (dex, name, types, base stats, avatars). Public-read like
# the board pages; no mutations.
class PokemonController < ApplicationController
  skip_before_action :require_authentication

  def index
    @pokemon = Pokemon.by_dex
    # One query for every type's color; the badges read it from this map so the
    # list/grid don't query per cell. {} when the enumerals aren't seeded yet.
    @type_colors = Pokemon.type_colors
  end
end
