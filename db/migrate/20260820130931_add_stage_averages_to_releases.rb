class AddStageAveragesToReleases < ActiveRecord::Migration[8.1]
  # The DevOps card's stage averages, precomputed at the end of a deployment.
  #
  # DEDICATED COLUMNS, not the shared `metadata` jsonb, and that is the entire
  # point of this migration. The first attempt stored the snapshot in metadata and
  # it was erased four lines after it was written: Release::Conductor.ship! calls
  # release.ship! (which writes the snapshot through a freshly-loaded instance),
  # then stamp_session_mascot on its own now-stale object, whose
  # `update!(metadata: meta)` rewrites the WHOLE blob without the new key. Four
  # writers rewrite that column wholesale, so reordering one of them would only be
  # whack-a-mole against the class.
  #
  # This mirrors duration_metrics / duration_metrics_cached_at /
  # duration_cache_version (Release::DurationCache), which solved the same problem
  # the same way and is immune for the same reason.
  def change
    add_column :releases, :stage_averages, :jsonb, default: {}, null: false
    add_column :releases, :stage_averages_cached_at, :datetime
    add_column :releases, :stage_averages_version, :integer, default: 0, null: false
  end
end
