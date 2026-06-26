class AddAvatarFallbackUrlToPokemons < ActiveRecord::Migration[7.2]
  # avatar_url becomes the tightly-cropped primary; avatar_fallback_url keeps the
  # original uncropped official-artwork as a backup (and what `display_avatar`
  # falls back to). The seed (db/seeds/data/pokemon.json) carries both for all 151.
  def change
    add_column :pokemons, :avatar_fallback_url, :string
  end
end
