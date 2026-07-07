class CreateNflTeamTotalProjections < ActiveRecord::Migration[8.1]
  def change
    create_table :nfl_team_total_projections do |t|
      t.string :season_slug, null: false
      t.string :slate_slug, null: false
      t.string :game_slug, null: false
      t.integer :week, null: false
      t.string :team_slug, null: false
      t.string :opponent_team_slug, null: false
      t.boolean :home, null: false
      t.decimal :expected_points, precision: 5, scale: 2, null: false
      t.decimal :game_total, precision: 5, scale: 2, null: false
      t.decimal :home_spread, precision: 5, scale: 2, null: false
      t.string :favorite_team_slug, null: false
      t.decimal :favorite_spread, precision: 5, scale: 2, null: false
      t.string :source, null: false
      t.string :source_url
      t.date :source_published_on
      t.datetime :cached_at, null: false

      t.timestamps
    end

    add_index :nfl_team_total_projections, [:game_slug, :team_slug], unique: true, name: "idx_nfl_team_totals_on_game_team"
    add_index :nfl_team_total_projections, [:season_slug, :week, :team_slug], name: "idx_nfl_team_totals_on_season_week_team"
    add_index :nfl_team_total_projections, [:slate_slug, :team_slug], name: "idx_nfl_team_totals_on_slate_team"
    add_index :nfl_team_total_projections, :source
  end
end
