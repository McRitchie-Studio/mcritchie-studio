# The operator's recast for one on-screen performer (recast pipeline, piece 2):
# the athlete who replaces them and which of that athlete's looks, or an
# explicit "keep as is". Slug FKs, like every other pointer on this table.
# Schema only: every existing performer starts undecided, so no backfill.
class AddRecastToVideoPerformers < ActiveRecord::Migration[8.1]
  def change
    add_column :video_performers, :recast_person_slug, :string
    add_column :video_performers, :recast_appearance_slug, :string
    add_column :video_performers, :recast_keep, :boolean, null: false, default: false
    add_index :video_performers, :recast_person_slug
    add_index :video_performers, :recast_appearance_slug
  end
end
