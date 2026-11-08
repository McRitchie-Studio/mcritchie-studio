# The Egnyte domains the hub reads and writes (a document store), stored by the
# sign-in itself (/admin/egnyte/callback) so nobody copies a token by hand. One
# row per Egnyte domain (`domain`, unique: the subdomain of <domain>.egnyte.com,
# since Egnyte's Public API answers on each domain's own host). Both tokens are
# encrypted at rest by the model (Active Record Encryption), so the columns hold
# ciphertext. Egnyte's access token lives 30 days and its refresh token rotates
# on every refresh, so the access token is kept (with its expiry) and refreshed
# only when it is near the end. A new table: no existing row is read or
# written, and no data step is owed.
class CreateEgnyteConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :egnyte_connections do |t|
      t.string :domain, null: false
      t.string :username
      t.text :access_token, null: false
      t.datetime :access_expires_at
      t.text :refresh_token
      t.string :connected_by
      t.datetime :connected_at, null: false
      t.datetime :last_refreshed_at
      t.timestamps
    end
    add_index :egnyte_connections, :domain, unique: true
  end
end
