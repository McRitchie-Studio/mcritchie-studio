# Generated takes for the recast pipeline (piece 3). The operator swaps a chunk
# by hand and uploads the MP4 back; each upload is a numbered take, kept, never
# overwritten. A take belongs to a chunk by the video's slug and the chunk's
# ordinal AND window, not by row id: bin/find-clips --tile replaces the chunk
# rows, and a take must survive a re-tile that cuts the same windows.
# current_since picks the current take: the latest wins, so a new upload is
# current and the operator can put an older one back in front.
# video_clips gains the per-chunk "request regenerate" flag and its note.
# Schema only: no chunk has a take or a flag yet, so no backfill.
class CreateVideoChunkTakes < ActiveRecord::Migration[8.1]
  def change
    create_table :video_chunk_takes do |t|
      t.string :music_video_slug, null: false
      t.integer :chunk_ordinal, null: false
      t.integer :number, null: false
      t.integer :start_ms, null: false
      t.integer :end_ms, null: false
      t.string :object_key, null: false
      t.bigint :byte_size, null: false
      t.string :original_filename
      t.datetime :current_since, null: false
      t.timestamps
      t.index %i[music_video_slug chunk_ordinal number], unique: true,
                                                         name: "index_video_chunk_takes_on_video_chunk_and_number"
      t.index :object_key, unique: true
    end

    add_column :video_clips, :regenerate_requested_at, :datetime
    add_column :video_clips, :regenerate_note, :string
  end
end
