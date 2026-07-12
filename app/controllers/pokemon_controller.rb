# Read-only Pokédex for spawned session Pokémon and mascot-bearing actions.
# Public-read like the board pages; no mutations.
class PokemonController < ApplicationController
  skip_before_action :require_authentication

  def index
    @pokedex = PokemonPokedex.new
    @newest_unique = @pokedex.newest_unique
    @newest_caught = @pokedex.newest_caught
    @newest_unique_shiny = @pokedex.newest_unique_shiny
    @newest_caught_shiny = @pokedex.newest_caught_shiny
    @recent_actions = @pokedex.recent_actions
  end
end
