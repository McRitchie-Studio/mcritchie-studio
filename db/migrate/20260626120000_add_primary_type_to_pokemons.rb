class AddPrimaryTypeToPokemons < ActiveRecord::Migration[7.2]
  # Denormalized cache of each Pokémon's identifying (least-common) type — the one
  # that drives its color. Populated by Pokemon.assign_primary_types! (the seed
  # runs it), so it is nullable and reads fall back to the live computation until
  # backfilled.
  def change
    add_column :pokemons, :primary_type, :string
  end
end
