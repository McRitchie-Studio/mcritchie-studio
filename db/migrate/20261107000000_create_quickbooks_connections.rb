# The QuickBooks Online companies the hub reads (company info and reports),
# stored by the sign-in itself (/admin/quickbooks/callback) so nobody copies a
# token by hand. One row per company (`realm_id`, Intuit's company id, unique):
# an owner may connect more than one company, each its own grant. The refresh
# token is encrypted at rest by the model (Active Record Encryption), so the
# column holds ciphertext. Intuit rotates refresh tokens: every refresh may
# answer a new one, stored over the old and stamped in last_refreshed_at, with
# the expiry Intuit states. A new table: no existing row is read or written,
# and no data step is owed.
class CreateQuickbooksConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :quickbooks_connections do |t|
      t.string :realm_id, null: false
      t.string :company_name
      t.string :environment, null: false
      t.text :refresh_token, null: false
      t.datetime :refresh_token_expires_at
      t.string :connected_by
      t.datetime :connected_at, null: false
      t.datetime :last_refreshed_at
      t.timestamps
    end
    add_index :quickbooks_connections, :realm_id, unique: true
    add_index :quickbooks_connections, :connected_at
  end
end
