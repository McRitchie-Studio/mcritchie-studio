class AddLogoMetadataToTeams < ActiveRecord::Migration[7.2]
  def change
    add_column :teams, :logo_url, :string
    add_column :teams, :logo_path, :string
    add_column :teams, :logo_source, :string
  end
end
