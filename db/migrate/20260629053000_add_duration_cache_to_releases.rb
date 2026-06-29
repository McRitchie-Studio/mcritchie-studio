class AddDurationCacheToReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :releases, :duration_metrics, :jsonb, null: false, default: {}
    add_column :releases, :duration_metrics_cached_at, :datetime
    add_column :releases, :duration_cache_version, :integer, null: false, default: 1
  end
end
