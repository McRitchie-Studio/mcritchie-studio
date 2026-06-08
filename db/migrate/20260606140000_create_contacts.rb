class CreateContacts < ActiveRecord::Migration[7.2]
  def change
    create_table :contacts do |t|
      t.string :email, null: false
      t.string :first_name
      t.string :last_name
      t.string :tags, array: true, null: false, default: []
      t.boolean :subscribed, null: false, default: true
      t.datetime :unsubscribed_at
      t.string :unsubscribe_token, null: false
      t.string :source  # e.g. "hubspot_import", "manual"

      t.timestamps
    end

    add_index :contacts, "lower(email)", unique: true, name: "index_contacts_on_lower_email"
    add_index :contacts, :unsubscribe_token, unique: true
    add_index :contacts, :tags, using: :gin
  end
end
