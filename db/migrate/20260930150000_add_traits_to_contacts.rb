# What other apps know about a contact (task contact-traits-from-cyvasse),
# namespaced by source: traits["cyvasse"] holds the player's username, games,
# record and rank for the personalized Cyvasse emails. Each importer owns its
# own key and never writes another's. No index: the list is ~19k rows and the
# one filter on it (Contact.with_cyvasse_games) reads fine as a scan.
class AddTraitsToContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :contacts, :traits, :jsonb, default: {}, null: false
  end
end
