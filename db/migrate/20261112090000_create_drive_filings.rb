# The audit log of every Drive write the hub makes through a connection's
# drive ability (GoogleConnect::DriveFiler, /tasks/drive-filing): one row per
# folder made or file filed, dry or applied. It keeps the account address as a
# string, not a key to google_connections, so the record outlives a
# disconnect. It stores the folder path, the file's name, size and md5 and the
# Drive id Google answered, never the file's bytes. A new table: no existing
# row is read or written, and no data step is owed.
class CreateDriveFilings < ActiveRecord::Migration[8.1]
  def change
    create_table :drive_filings do |t|
      t.string :mailbox, null: false
      t.string :action, null: false
      t.string :folder_path, null: false
      t.string :file_name
      t.string :md5
      t.bigint :byte_size
      t.string :source
      t.string :drive_file_id
      t.boolean :applied, null: false, default: false
      t.boolean :duplicate, null: false, default: false
      t.string :requested_by, null: false
      t.text :error
      t.timestamps
    end
    add_index :drive_filings, %i[mailbox created_at]
    add_check_constraint :drive_filings, "action IN ('mkdir', 'upload')", name: "drive_filings_action_known"
  end
end
