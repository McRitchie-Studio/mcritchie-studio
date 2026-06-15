class CreateGithubCommitRanges < ActiveRecord::Migration[7.2]
  def change
    create_table :github_commit_ranges do |t|
      t.date :week_start_date, null: false
      t.date :week_end_date, null: false
      t.string :label, null: false

      t.timestamps
    end
    add_index :github_commit_ranges, :week_start_date, unique: true
    add_index :github_commit_ranges, :week_end_date

    create_table :github_builder_commit_range_caches do |t|
      t.references :tracked_github_builder,
        null: false,
        foreign_key: true,
        index: { name: "index_builder_range_caches_on_builder_id" }
      t.references :github_commit_range,
        null: false,
        foreign_key: true,
        index: { name: "index_builder_range_caches_on_range_id" }
      t.string :github_login, null: false
      t.string :cohort, null: false
      t.integer :commits_count, null: false, default: 0
      t.integer :non_merge_commits_count, null: false, default: 0
      t.integer :bot_adjusted_commits_count, null: false, default: 0
      t.integer :active_repos_count, null: false, default: 0
      t.decimal :trailing_90d_avg_weekly_commits, precision: 12, scale: 4
      t.decimal :builder_multiple, precision: 12, scale: 4
      t.decimal :bot_adjusted_builder_multiple, precision: 12, scale: 4
      t.jsonb :commit_shas, null: false, default: []
      t.datetime :cached_at, null: false

      t.timestamps
    end
    add_index :github_builder_commit_range_caches,
      [:tracked_github_builder_id, :github_commit_range_id],
      unique: true,
      name: "idx_builder_range_caches_on_builder_range"
    add_index :github_builder_commit_range_caches, [:github_login, :github_commit_range_id],
      name: "idx_builder_range_caches_on_login_range"
    add_index :github_builder_commit_range_caches, [:github_commit_range_id, :cohort],
      name: "idx_builder_range_caches_on_range_cohort"
  end
end
