class AddIncludedInRosterToBuilders < ActiveRecord::Migration[7.2]
  def change
    add_column :builders, :included_in_roster, :boolean, null: false, default: true
    add_index :builders, [:active, :included_in_roster], name: "index_builders_on_active_and_included_in_roster"
  end
end
