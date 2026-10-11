# The brand kit record (epic brand-studio, piece 3; task brand-kit-record): one row
# per brand in config/logo_brands.yml, holding the operator's SAVED Navbar Logo and
# Stacked Logo choices (rule or form, text version, part edits) and, through Active
# Storage (`originals`), the brand's original artwork. A new table, so no lock on
# anything that serves traffic; nothing is backfilled (a kit is created on its
# first save). `brand` is the style key, the slug the gallery's URLs use.
class CreateBrandKits < ActiveRecord::Migration[8.1]
  def change
    create_table :brand_kits do |t|
      t.string :brand, null: false
      t.jsonb :navbar_choice
      t.jsonb :stacked_choice
      t.text :notes
      t.string :updated_by
      t.timestamps
    end
    add_index :brand_kits, :brand, unique: true
  end
end
