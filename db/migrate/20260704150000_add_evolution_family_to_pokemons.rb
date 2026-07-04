# Evolutionary family columns for the mascot system. `base` names the family's
# spawnable root (charizard → "charmander"; snorlax → "snorlax"; a baby points
# at the family base, cleffa → "clefairy"). `evolution` lists the slugs this
# form can evolve INTO next (eevee carries five; charmeleon carries
# ["charizard"]). `baby` rides on the base and lists its baby forms (pikachu →
# ["pichu"]; all three Hitmons carry ["tyrogue"]). Values are derived from
# PokéAPI species links by `rake pokemon:fetch` and seeded from the committed
# JSON — clipped to Gen 1–2, so out-of-range relatives (Munchlax, Magmortar)
# don't exist here.
class AddEvolutionFamilyToPokemons < ActiveRecord::Migration[8.1]
  def change
    add_column :pokemons, :base, :string
    add_column :pokemons, :evolution, :jsonb, null: false, default: []
    add_column :pokemons, :baby, :jsonb, null: false, default: []
  end
end
