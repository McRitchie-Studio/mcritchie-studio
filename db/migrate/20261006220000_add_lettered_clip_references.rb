# Lettered clip references (recast pipeline, piece 16).
#
#   appearances.jersey_number       the number a look wears, so a clip prompt can
#                                   name a player as "#4 Dak Prescott". Nullable;
#                                   no backfill: set when a look is made or its
#                                   sheet generated, and editable on the person page.
#   video_clips.reference_frames    a chunk's lettered reference frames, written
#                                   whole by bin/clip-references --apply:
#                                   [{ object_key, t_ms, letters }]. jsonb on the
#                                   row, like alt_videos.swaps: written once per
#                                   run, read whole, never queried by entry.
class AddLetteredClipReferences < ActiveRecord::Migration[8.1]
  def change
    add_column :appearances, :jersey_number, :integer
    add_column :video_clips, :reference_frames, :jsonb, default: [], null: false
  end
end
