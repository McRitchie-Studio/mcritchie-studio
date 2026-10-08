# The TikTok account the hub drafts to, stored by the sign-in itself
# (/admin/tiktok/callback) so nobody copies a token by hand. One row per TikTok
# account (open_id, unique); the refresh token is encrypted at rest by the model
# (Active Record Encryption), so the column holds ciphertext. A new table: no
# existing row is read or written, and no data step is owed.
class CreateTiktokConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :tiktok_connections do |t|
      t.string :open_id, null: false
      t.text :refresh_token, null: false
      t.string :scope
      t.string :display_name
      t.string :connected_by
      t.datetime :connected_at, null: false
      t.datetime :refreshed_at
      t.datetime :refresh_expires_at
      t.timestamps
    end
    add_index :tiktok_connections, :open_id, unique: true
    add_index :tiktok_connections, :connected_at
  end
end
