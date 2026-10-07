# THE FICTIONAL CAST (epic email-image-builder, addendum "Characters", piece A).
#
# Person stays the table of REAL humans. A Character is one of ours: a mascot
# (Turf Monster) or a puppet. A look (Appearance) now belongs to EXACTLY ONE of
# the two, and so does a subject row on an artifact, so a character's sheet is
# filed and found the same way a person's is.
#
# Every existing appearance and artifact_subjects row names a person, so the
# CHECK constraints hold on the rows already on file; the NOT NULL is dropped
# only to make room for the other owner. No data moves here: Turf Monster is
# seeded by `bin/rails characters:seed_turf_monster` (the post_deploy_cmd).
class CreateCharacters < ActiveRecord::Migration[8.1]
  def change
    create_table :characters do |t|
      t.string :slug, null: false
      t.string :name, null: false
      # mascot | puppet, validated in the model and by the CHECK below.
      t.string :kind, null: false
      # A brand-kit key from config/email_brand_kits.yml (e.g. turf-monster).
      t.string :brand
      t.text :bio
      t.text :personality
      t.text :voice_notes
      # Same semantics as people.default_appearance_slug (resolved, released).
      t.string :default_appearance_slug
      t.string :avatar_url
      t.datetime :retired_at
      t.timestamps
    end
    add_index :characters, :slug, unique: true
    add_index :characters, :brand
    add_check_constraint :characters, "kind IN ('mascot', 'puppet')", name: "characters_kind_known"
    # The same key people.default_appearance_slug carries (AddSlugForeignKeys):
    # a deleted look clears the pointer, and Appearance re-points the holder.
    add_foreign_key :characters, :appearances, column: :default_appearance_slug, primary_key: :slug,
                                               on_update: :cascade, on_delete: :nullify

    add_column :appearances, :character_slug, :string
    add_index :appearances, :character_slug
    add_index :appearances, %i[character_slug descriptor], unique: true, where: "retired_at IS NULL",
                                                           name: "index_appearances_live_per_character"
    add_foreign_key :appearances, :characters, column: :character_slug, primary_key: :slug, on_update: :cascade
    change_column_null :appearances, :person_slug, true
    add_check_constraint :appearances, "num_nonnulls(person_slug, character_slug) = 1",
                         name: "appearances_exactly_one_owner"

    add_column :artifact_subjects, :character_slug, :string
    add_index :artifact_subjects, :character_slug
    add_index :artifact_subjects, %i[artifact_slug character_slug], unique: true,
                                                                     where: "character_slug IS NOT NULL",
                                                                     name: "index_artifact_subjects_on_artifact_and_character"
    add_foreign_key :artifact_subjects, :characters, column: :character_slug, primary_key: :slug, on_update: :cascade
    change_column_null :artifact_subjects, :person_slug, true
    add_check_constraint :artifact_subjects, "num_nonnulls(person_slug, character_slug) = 1",
                         name: "artifact_subjects_exactly_one_owner"
  end
end
