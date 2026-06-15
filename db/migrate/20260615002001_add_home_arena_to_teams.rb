class AddHomeArenaToTeams < ActiveRecord::Migration[7.2]
  def change
    add_column :teams, :home_arena_slug, :string
    add_index :teams, :home_arena_slug
  end
end
