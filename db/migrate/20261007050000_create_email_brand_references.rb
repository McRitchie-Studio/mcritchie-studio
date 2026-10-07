# Uploaded reference images for an email brand kit (epic email-image-builder,
# task email-brand-asset-page). The kit itself stays the git-reviewed
# config/email_brand_kits.yml; these rows are the references an admin adds on
# /email_images/brand_kits/<kit> before a round. EmailImages::BrandKit merges
# the active rows with the YAML references in one place.
#
# A NEW TABLE, not appearance_reference_photos: that table is a person's look
# (appearance_slug NOT NULL, face scores, operator verdicts on a likeness).
# These are our own marks and mascots, keyed by brand kit, with a role and a
# usage note, and must never carry a person.
class CreateEmailBrandReferences < ActiveRecord::Migration[8.1]
  def change
    create_table :email_brand_references do |t|
      t.string :slug, null: false
      # A kit key in config/email_brand_kits.yml (validated in the model; the
      # kits are YAML, so there is no row to point a foreign key at).
      t.string :brand_kit, null: false
      # mascot | logo | style | product | other, validated in the model.
      t.string :role, null: false
      t.string :label, null: false
      t.text :note
      t.text :image_url, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.integer :width
      t.integer :height
      t.string :uploaded_by
      t.datetime :archived_at
      t.timestamps
    end
    add_index :email_brand_references, :slug, unique: true
    add_index :email_brand_references, %i[brand_kit archived_at]
  end
end
