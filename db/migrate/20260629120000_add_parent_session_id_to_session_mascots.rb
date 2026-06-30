class AddParentSessionIdToSessionMascots < ActiveRecord::Migration[8.1]
  def change
    add_column :session_mascots, :parent_session_id, :string
    add_index :session_mascots, :parent_session_id
  end
end
