# The Fathom accounts the hub reads (meeting notes and transcripts), stored by
# the sign-in itself (/admin/fathom/callback) so nobody copies a token by hand.
# One row per Fathom account (`account`, unique): the recorder's email when the
# API names it, else a label. The refresh token is encrypted at rest by the
# model (Active Record Encryption), so the column holds ciphertext. Fathom
# refresh tokens are single-use: every refresh replaces the stored one and
# stamps last_refreshed_at. A new table: no existing row is read or written,
# and no data step is owed.
class CreateFathomConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :fathom_connections do |t|
      t.string :account, null: false
      t.text :refresh_token, null: false
      t.string :connected_by
      t.datetime :connected_at, null: false
      t.datetime :last_refreshed_at
      t.timestamps
    end
    add_index :fathom_connections, :account, unique: true
    add_index :fathom_connections, :connected_at
  end
end
