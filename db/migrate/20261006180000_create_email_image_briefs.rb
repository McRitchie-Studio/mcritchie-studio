# Email header briefs (epic email-image-builder, piece 1). A brief is the
# request; its candidates are Artifact rows of kind `email_header` joined by
# `artifacts.brief_slug`, so provenance, cost, approve and retire are reused.
class CreateEmailImageBriefs < ActiveRecord::Migration[8.1]
  def change
    create_table :email_image_briefs do |t|
      t.string :slug, null: false
      t.string :app, null: false
      t.string :email_key, null: false
      t.string :variant, null: false, default: "default"
      t.string :brand_kit, null: false
      t.string :preset, null: false, default: "header_2x1"
      # baked | none today; composited arrives in piece 3, so this is a string
      # validated in the model rather than a database enum.
      t.string :text_mode, null: false, default: "baked"
      t.string :image_format, null: false, default: "jpg"
      t.string :headline, null: false
      t.string :subtext
      t.string :alt_text
      t.text :prompt_notes
      t.string :generator_key
      t.integer :max_rounds, null: false, default: 4
      t.integer :rounds_used, null: false, default: 0
      t.string :build_state
      t.datetime :build_started_at
      t.datetime :build_finished_at
      t.text :build_error
      t.string :approved_artifact_slug
      t.datetime :exported_at
      t.string :exported_to
      t.string :created_by
      t.timestamps
    end
    add_index :email_image_briefs, :slug, unique: true
    add_index :email_image_briefs, %i[app email_key variant], unique: true

    add_column :artifacts, :brief_slug, :string
    add_index :artifacts, :brief_slug
  end
end
