# The recast pipeline tiles a whole video into overlapping chunks
# (bin/find-clips --tile) and stores them beside the seam-picked candidates.
# kind tells the two sets apart; each numbers its own ordinals from 1. A chunk
# has no seam, so seam becomes nullable. Existing rows are all candidates.
#
# The tiling's chunk length and overlap are parameters (25 s and 5 s by
# default), so the video records the ones its current chunks were cut with;
# both stay null until a video is tiled.
class AddChunkTilingToVideoClips < ActiveRecord::Migration[8.1]
  def change
    add_column :video_clips, :kind, :string, null: false, default: "candidate"
    change_column_null :video_clips, :seam, true
    remove_index :video_clips, column: [:music_video_slug, :ordinal], unique: true
    add_index :video_clips, [:music_video_slug, :kind, :ordinal], unique: true

    add_column :music_videos, :chunk_ms, :integer
    add_column :music_videos, :chunk_overlap_ms, :integer
  end
end
