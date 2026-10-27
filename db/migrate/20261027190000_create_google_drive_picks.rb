# The Drive files a person chose in the Google Picker for one GoogleConnection
# (task drive-files-you-pick). Under the drive.file permission Google lets the
# app read only these; the row is the hub's record of what was handed over.
# Deleting a connection (GoogleSignIn#disconnect_all uses delete_all) takes its
# picks with it at the database, so no pick outlives its token.
class CreateGoogleDrivePicks < ActiveRecord::Migration[8.1]
  def change
    create_table :google_drive_picks do |t|
      t.references :google_connection, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :file_id, null: false
      t.string :name, null: false
      t.string :mime_type
      t.string :url
      t.string :picked_by
      t.datetime :picked_at, null: false
      t.timestamps
    end
    add_index :google_drive_picks, %i[google_connection_id file_id], unique: true
  end
end
