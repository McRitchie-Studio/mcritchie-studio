# A look can belong to one music video and the performer it was built from
# (music video pipeline, stage 4). Both nullable: athlete looks carry neither.
class AddMusicVideoLookToAppearances < ActiveRecord::Migration[8.1]
  def change
    add_column :appearances, :music_video_slug, :string
    add_column :appearances, :performer_ordinal, :integer
    add_index :appearances, [:music_video_slug, :performer_ordinal], unique: true,
              where: "music_video_slug IS NOT NULL AND retired_at IS NULL",
              name: "index_appearances_one_live_look_per_performer"
  end
end
