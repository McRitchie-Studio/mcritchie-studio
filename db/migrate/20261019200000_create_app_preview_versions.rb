# The shared client-app host (.agents/epics/client-app-zero-to-one.md; docs:
# docs/agents/system/client-app-host.md). Every /build app's first version is a
# static bundle served at <sub>.<preview domain>.
#
# apps.preview_version names the LIVE bundle; flipping it is the publish.
# app_preview_versions is the small history: one row per published bundle, with
# the manifest the host serves from (a path not in it is never fetched).
class CreateAppPreviewVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :app_preview_versions do |t|
      t.string :app_slug, null: false
      t.string :version, null: false
      t.string :published_by
      t.integer :file_count, null: false
      t.integer :byte_size, null: false
      # { path => { "size", "sha256", "content_type" } }
      t.jsonb :manifest, null: false, default: {}
      t.datetime :published_at, null: false
      t.timestamps
    end
    add_index :app_preview_versions, %i[app_slug version], unique: true
    add_index :app_preview_versions, %i[app_slug published_at]
    add_foreign_key :app_preview_versions, :apps, column: :app_slug, primary_key: :slug,
                                                  on_update: :cascade, on_delete: :cascade

    add_column :apps, :preview_version, :string
  end
end
