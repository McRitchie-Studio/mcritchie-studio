# Read-only Pokédex for spawned session Pokémon and mascot-bearing actions.
# Admin-only, like the board pages (AdminWall); no mutations.
class PokemonController < ApplicationController
  def index
    @pokedex = PokemonPokedex.new
    @newest_unique = @pokedex.newest_unique
    @newest_caught = @pokedex.newest_caught
    @newest_unique_shiny = @pokedex.newest_unique_shiny
    @newest_caught_shiny = @pokedex.newest_caught_shiny
    @recent_actions = @pokedex.recent_actions
    @dex_entries = @pokedex.dex_entries
  end
end
