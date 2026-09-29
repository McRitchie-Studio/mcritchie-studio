# Stage 5, clips: ~25 s windows of a music video proposed by bin/find-clips,
# cut to R2, each with a filled swap prompt. The operator approves or rejects.
# Slug FK and performer ordinals, no DB foreign keys, like the rest of the app.
class CreateVideoClips < ActiveRecord::Migration[8.1]
  def change
    create_table :video_clips do |t|
      t.string :music_video_slug, null: false
      t.integer :ordinal, null: false
      t.integer :start_ms, null: false
      t.integer :end_ms, null: false
      t.string :seam, null: false
      t.integer :seam_ms
      t.string :cast_shape, null: false
      t.integer :target_performer
      t.jsonb :performer_ordinals, null: false, default: []
      t.string :object_key, null: false
      t.text :prompt, null: false
      t.string :status, null: false, default: "proposed"
      t.timestamps
    end
    add_index :video_clips, [:music_video_slug, :ordinal], unique: true
  end
end
