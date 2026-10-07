# Iced-out twin looks and the jewelry a person owns (recast epic, piece 15).
#
# appearances.iced: this look is the iced-out variant; its sheet is built from
#   the iced prompt (Appearances::CharacterSheetPrompt, iced: true).
# appearances.base_appearance_slug: the look it is the iced twin of (slug FK).
#   One live twin per base, enforced by the partial unique index.
# person_jewelries: what a person wears that a prompt can name (a Super Bowl
#   ring, a chain), the source of truth for the iced sheet's jewelry clause.
class AddIcedTwinsAndPersonJewelries < ActiveRecord::Migration[8.1]
  def change
    add_column :appearances, :iced, :boolean, null: false, default: false
    add_column :appearances, :base_appearance_slug, :string
    add_index :appearances, :base_appearance_slug, unique: true,
              where: "base_appearance_slug IS NOT NULL AND retired_at IS NULL",
              name: "index_appearances_one_live_twin_per_base"

    create_table :person_jewelries do |t|
      t.string :slug, null: false
      t.string :person_slug, null: false
      t.string :kind, null: false
      t.string :name, null: false
      t.integer :year
      t.text :description, null: false
      t.string :image_url
      t.string :source
      t.timestamps
    end
    add_index :person_jewelries, :slug, unique: true
    add_index :person_jewelries, [:person_slug, :kind]
  end
end
