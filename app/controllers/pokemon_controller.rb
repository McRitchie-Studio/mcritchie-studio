# Read-only Pokédex for spawned session Pokémon and mascot-bearing actions.
# Public-read like the board pages; no mutations.
class PokemonController < ApplicationController
  skip_before_action :require_authentication

  def index
    @pokedex = PokemonPokedex.new
    @latest_spawn = @pokedex.latest_spawn
    @latest_shiny_spawn = @pokedex.latest_shiny_spawn
    @recent_actions = @pokedex.recent_actions
  end
end
