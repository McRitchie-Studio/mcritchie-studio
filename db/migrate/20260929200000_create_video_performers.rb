# The cast stage: Person 1..N on a music video, grouped by visible cues by the
# agent's vision pass. artist_slug is set by the operator; `extra` marks someone
# who is not a named artist. Slug FKs, no DB foreign keys, like the rest of the app.
class CreateVideoPerformers < ActiveRecord::Migration[8.1]
  def change
    create_table :video_performers do |t|
      t.string :music_video_slug, null: false
      t.integer :ordinal, null: false
      t.string :label, null: false
      t.string :artist_slug
      t.boolean :extra, null: false, default: false
      t.jsonb :still_object_keys, null: false, default: []
      t.jsonb :sightings, null: false, default: []
      t.text :confidence_note
      t.timestamps
    end
    add_index :video_performers, [:music_video_slug, :ordinal], unique: true
    add_index :video_performers, :artist_slug
  end
end
