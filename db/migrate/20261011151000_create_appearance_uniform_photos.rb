# Game-action photos of a look's uniform (task player-sheet-uniform-and-build): the
# sheet copies badges, patch placement, stripes, pants and socks from them, never a
# face. A NEW TABLE rather than a role on appearance_reference_photos, because every
# query over that table is a face query (ReferenceSet, eligibility, the trainer's
# list, the gallery counts); a uniform photo there would have to be excluded from
# each one by hand, and a missed exclusion would put another player's face into
# this man's identity.
#
# `hosted_url` is OUR copy of the photo, made when the operator chooses it
# (Appearances::MirrorUniformPhoto); a build sends only hosted copies, never the
# search hit itself.
#
# A new table only: no existing row is read or written.
class CreateAppearanceUniformPhotos < ActiveRecord::Migration[8.1]
  def change
    create_table :appearance_uniform_photos do |t|
      t.string :slug, null: false
      t.string :appearance_slug, null: false
      t.text :image_url, null: false
      t.text :hosted_url
      t.text :thumb_url
      t.text :page_url
      t.text :title
      t.integer :width
      t.integer :height
      t.text :query
      t.string :provider
      t.integer :position
      t.boolean :chosen, null: false, default: false
      t.datetime :chosen_at
      t.timestamps
    end
    add_index :appearance_uniform_photos, :slug, unique: true
    add_index :appearance_uniform_photos, [:appearance_slug, :image_url], unique: true,
                                                                          name: "index_uniform_photos_unique_per_look"
    add_index :appearance_uniform_photos, [:appearance_slug, :chosen], name: "index_uniform_photos_per_look"
    add_foreign_key :appearance_uniform_photos, :appearances, column: :appearance_slug, primary_key: :slug,
                                                              on_update: :cascade, on_delete: :cascade
  end
end
