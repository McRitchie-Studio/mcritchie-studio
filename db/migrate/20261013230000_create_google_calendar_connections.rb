# The Google calendars the hub reads, stored by the sign-in itself
# (/admin/google_calendar/callback) so nobody copies a token by hand. One row
# per Google account (email, unique); the refresh token is encrypted at rest by
# the model (Active Record Encryption), so the column holds ciphertext. A new
# table: no existing row is read or written, and no data step is owed.
class CreateGoogleCalendarConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :google_calendar_connections do |t|
      t.string :email, null: false
      t.text :refresh_token, null: false
      t.string :scope
      t.string :connected_by
      t.datetime :connected_at, null: false
      t.timestamps
    end
    add_index :google_calendar_connections, :email, unique: true
    add_index :google_calendar_connections, :connected_at
  end
end
