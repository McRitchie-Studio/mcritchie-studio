class AddCacheKeyToGithubBuilderCommitRangeCaches < ActiveRecord::Migration[7.2]
  def change
    add_column :github_builder_commit_range_caches, :cache_run_key, :string, null: false, default: "legacy"
    add_index :github_builder_commit_range_caches, :cache_run_key, name: "idx_builder_range_caches_on_cache_run_key"
    add_index :github_builder_commit_range_caches,
      [:cache_run_key, :tracked_github_builder_id, :github_commit_range_id],
      name: "idx_builder_range_caches_on_run_key_builder_range"
  end
end
