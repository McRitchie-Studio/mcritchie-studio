# Mascot GENDER (tasks/pokemon-mascot-gender). A session's mascot now rolls a
# gender once, beside its shiny roll, weighted by the species' real PokéAPI
# gender_rate; the session's tasks adopt it as devops.mascot_gender.
#
# pokemons gains the reference data the roll and the art read:
#   gender_rate            — PokéAPI's eighths-female: -1 genderless, 0 always
#                            male, 8 always female, n = an n/8 chance of female.
#   has_gender_differences — the species has a distinct female sprite.
#   female_sprite_url /    — that female pixel sprite, normal and shiny (official
#   shiny_female_sprite_url  artwork has no female variants, so avatars stay put).
#   gender_forms           — { gender => slug } for a drawable FAMILY row whose
#                            gender picks the species it wears (nidoran →
#                            nidoran-f / nidoran-m).
#   evolution_genders      — { evolution slug => gender } a branch requires
#                            (nidoran → nidorina needs female). Data, not code, so
#                            later generations add Gallade/Froslass without code.
#
# The dex index stops being unique: the nidoran family row shares dex 29 with the
# Nidoran♀ species row it wears. The slug stays the unique identity (the seed
# upserts by slug).
class AddGenderToPokemonMascots < ActiveRecord::Migration[8.1]
  def change
    change_table :pokemons, bulk: true do |t|
      t.integer :gender_rate
      t.boolean :has_gender_differences, null: false, default: false
      t.string :female_sprite_url
      t.string :shiny_female_sprite_url
      t.jsonb :gender_forms, null: false, default: {}
      t.jsonb :evolution_genders, null: false, default: {}
    end

    remove_index :pokemons, :dex, unique: true, name: "index_pokemons_on_dex"
    add_index :pokemons, :dex, name: "index_pokemons_on_dex"

    add_column :session_mascots, :gender, :string
  end
end
