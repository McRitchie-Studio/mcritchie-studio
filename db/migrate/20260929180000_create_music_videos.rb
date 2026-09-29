# Music videos digested from a platform URL, and their credited artists. Slug
# FKs, no DB foreign keys, like the rest of the app. caption_timing holds cue
# times and section markers only; lyric text is never stored.
class CreateMusicVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :music_videos do |t|
      t.string :slug, null: false
      t.string :kind, null: false, default: "music_video"
      t.string :platform, null: false
      t.string :source_url, null: false
      t.string :source_id, null: false
      t.string :title, null: false
      t.integer :duration_ms
      t.string :stage, null: false, default: "digested"
      t.string :source_object_key, null: false
      t.string :info_object_key
      t.jsonb :caption_timing, null: false, default: { cues: [], sections: [] }
      t.jsonb :unresolved_credits, null: false, default: []
      t.timestamps
    end
    add_index :music_videos, :slug, unique: true
    add_index :music_videos, [:platform, :source_id], unique: true

    create_table :music_video_artists do |t|
      t.string :music_video_slug, null: false
      t.string :artist_slug, null: false
      t.string :role, null: false # primary | featured
      t.integer :position, null: false, default: 1
      t.timestamps
    end
    add_index :music_video_artists, [:music_video_slug, :artist_slug], unique: true
    add_index :music_video_artists, :artist_slug
  end
end
