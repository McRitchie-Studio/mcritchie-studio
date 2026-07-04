# Shiny artwork for every Pokémon — the same three-URL shape as the normal art
# (cropped primary / uncropped original / pixel sprite), mirrored into S3 by
# `rake pokemon:upload_images` + `rake pokemon:crop_and_upload` under additive
# *-shiny*.png keys. Whether a given MASCOT is shiny is a property of the draw
# (SessionMascot#shiny / devops.mascot_shiny), not of these reference rows.
class AddShinyUrlsToPokemons < ActiveRecord::Migration[8.1]
  def change
    add_column :pokemons, :shiny_avatar_url, :string
    add_column :pokemons, :shiny_avatar_fallback_url, :string
    add_column :pokemons, :shiny_sprite_url, :string
  end
end
