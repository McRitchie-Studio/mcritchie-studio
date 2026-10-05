# The final stitch of the recast pipeline (piece 4): the current takes of every
# chunk crossfaded into one full-length MP4 over the source audio. A stitch is
# requested on the page, run where ffmpeg is (a local hub's job, or
# bin/stitch-video on the Mac), and kept: stitch 1, stitch 2 ... per video,
# each its own object in R2 under the video's stitched/ folder.
# `takes` is the take each chunk had when the stitch was requested, by ordinal
# and window; the page reads it to mark a stitch stale once a chunk moves on.
# Slug FK to music_videos, like video_chunk_takes. Schema only: no backfill.
class CreateVideoStitches < ActiveRecord::Migration[8.1]
  def change
    create_table :video_stitches do |t|
      t.string :music_video_slug, null: false
      t.integer :number, null: false
      t.string :state, null: false, default: "requested"
      t.string :object_key, null: false
      t.jsonb :takes, null: false, default: []
      t.jsonb :warnings, null: false, default: []
      t.string :failure_reason
      t.integer :duration_ms
      t.bigint :byte_size
      t.integer :width
      t.integer :height
      t.string :frame_rate
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[music_video_slug number], unique: true
      t.index :object_key, unique: true
    end
  end
end
