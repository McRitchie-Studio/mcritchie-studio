# Read-only inspector for the seeded Pokémon reference data — a quick window onto
# the shape of the rows (dex, name, types, base stats, avatars). Public-read like
# the board pages; no mutations.
class PokemonController < ApplicationController
  skip_before_action :require_authentication

  def index
    @pokemon = Pokemon.by_dex
  end
end
