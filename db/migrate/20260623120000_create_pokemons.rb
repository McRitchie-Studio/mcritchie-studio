class CreatePokemons < ActiveRecord::Migration[7.2]
  def change
    create_table :pokemons do |t|
      t.integer :dex, null: false
      t.string :name, null: false
      t.string :slug, null: false
      t.string :types, array: true, null: false, default: []
      t.integer :hp
      t.integer :attack
      t.integer :defense
      t.integer :special_attack
      t.integer :special_defense
      t.integer :speed
      t.integer :generation, null: false, default: 1
      t.string :avatar_url
      t.string :sprite_url

      t.timestamps
    end

    add_index :pokemons, :dex, unique: true
    add_index :pokemons, :slug, unique: true
  end
end
