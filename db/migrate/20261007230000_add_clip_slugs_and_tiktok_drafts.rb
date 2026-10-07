# TikTok drafts from a clip (recast pipeline, piece 19).
#
#   alt_video_clips.slug   a stable, readable name for one clip, shown on its
#                          card, that the operator hands to the tiktok-draft SOP:
#                          "<alt video slug>-clip-<NN>", e.g.
#                          bigxthaplug-6wa-alt-3-clip-03. Derived from two
#                          columns that never change (alt_video_slug,
#                          chunk_ordinal), so the backfill below is the same
#                          rule the model applies to a new clip. Unique.
#
#   tiktok_drafts          one row per attempt to put a clip's primary version
#                          into the operator's TikTok drafts (the Content Posting
#                          API's inbox upload): which clip and version, the
#                          caption the code wrote, TikTok's publish_id and
#                          status, and any error, so a retry and its outcome are
#                          both visible. Slug FK to the clip, like the rest of
#                          the pipeline.
#
# DATA STEP: the backfill runs here, inside the schema migration (one UPDATE,
# bounded by the clips table, tens of rows in production), so it needs no
# post_deploy_cmd: the release phase's db:migrate runs it before the column
# turns NOT NULL.
class AddClipSlugsAndTiktokDrafts < ActiveRecord::Migration[8.1]
  def up
    add_column :alt_video_clips, :slug, :string
    execute <<~SQL.squish
      UPDATE alt_video_clips
         SET slug = alt_video_slug || '-clip-' || lpad(chunk_ordinal::text, greatest(2, length(chunk_ordinal::text)), '0')
       WHERE slug IS NULL
    SQL
    change_column_null :alt_video_clips, :slug, false
    add_index :alt_video_clips, :slug, unique: true

    create_table :tiktok_drafts do |t|
      t.string :clip_slug, null: false
      t.integer :version_number, null: false
      t.string :version_object_key, null: false
      t.text :caption, null: false
      t.jsonb :facts, null: false, default: {}
      t.string :state, null: false, default: "queued"
      t.string :publish_id
      t.string :tiktok_status
      t.string :fail_reason
      t.text :error
      t.bigint :byte_size
      t.integer :chunk_count
      t.string :requested_by
      t.datetime :uploaded_at
      t.datetime :polled_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[clip_slug created_at]
      t.index :publish_id, unique: true, where: "publish_id IS NOT NULL"
      t.index :state
    end
  end

  def down
    drop_table :tiktok_drafts
    remove_index :alt_video_clips, :slug
    remove_column :alt_video_clips, :slug
  end
end
