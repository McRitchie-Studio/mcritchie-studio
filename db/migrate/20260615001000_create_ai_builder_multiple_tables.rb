class CreateAiBuilderMultipleTables < ActiveRecord::Migration[7.2]
  def change
    create_table :tracked_github_builders do |t|
      t.string :github_login, null: false
      t.string :display_name
      t.string :cohort, null: false
      t.string :category
      t.text :notes
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :tracked_github_builders, :github_login, unique: true
    add_index :tracked_github_builders, [:cohort, :active]

    create_table :tracked_github_builder_repos do |t|
      t.references :tracked_github_builder,
        null: false,
        foreign_key: true,
        index: { name: "index_builder_repos_on_builder_id" }
      t.string :repo_full_name, null: false
      t.string :repo_category
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :tracked_github_builder_repos, [:tracked_github_builder_id, :repo_full_name],
      unique: true,
      name: "index_builder_repos_on_builder_and_repo"
    add_index :tracked_github_builder_repos, :repo_full_name

    create_table :github_commit_observations do |t|
      t.string :github_login, null: false
      t.string :repo_full_name, null: false
      t.string :sha, null: false
      t.string :author_login
      t.string :committer_login
      t.datetime :authored_at
      t.datetime :committed_at
      t.text :message
      t.string :html_url
      t.boolean :is_merge, null: false, default: false
      t.boolean :is_bot, null: false, default: false
      t.string :source_strategy, null: false
      t.jsonb :raw_payload, null: false, default: {}

      t.timestamps
    end
    add_index :github_commit_observations, [:repo_full_name, :sha, :github_login],
      unique: true,
      name: "index_commit_observations_on_repo_sha_login"
    add_index :github_commit_observations, [:github_login, :committed_at]
    add_index :github_commit_observations, [:github_login, :authored_at]
    add_index :github_commit_observations, :source_strategy

    create_table :github_builder_weekly_metrics do |t|
      t.string :github_login, null: false
      t.string :cohort, null: false
      t.date :week_start_date, null: false
      t.integer :commits_count, null: false, default: 0
      t.integer :non_merge_commits_count, null: false, default: 0
      t.integer :bot_adjusted_commits_count, null: false, default: 0
      t.integer :active_repos_count, null: false, default: 0
      t.decimal :trailing_90d_avg_weekly_commits, precision: 12, scale: 4
      t.decimal :builder_multiple, precision: 12, scale: 4
      t.decimal :bot_adjusted_builder_multiple, precision: 12, scale: 4

      t.timestamps
    end
    add_index :github_builder_weekly_metrics, [:github_login, :week_start_date],
      unique: true,
      name: "index_builder_weekly_metrics_on_login_week"
    add_index :github_builder_weekly_metrics, [:week_start_date, :cohort]

    create_table :github_builder_index_weeks do |t|
      t.date :week_start_date, null: false
      t.decimal :ai_builder_multiple, precision: 12, scale: 4
      t.decimal :control_builder_multiple, precision: 12, scale: 4
      t.decimal :difficulty_adjusted_ai_builder_multiple, precision: 12, scale: 4
      t.integer :ai_builder_count, null: false, default: 0
      t.integer :control_builder_count, null: false, default: 0
      t.text :notes

      t.timestamps
    end
    add_index :github_builder_index_weeks, :week_start_date, unique: true
  end
end
