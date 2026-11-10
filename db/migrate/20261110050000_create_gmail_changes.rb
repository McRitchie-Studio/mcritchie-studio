# The audit log of every Gmail change the hub makes through a connection's
# opt-in gmail_organize ability (GoogleConnect::GmailEditor,
# /tasks/gmail-organize-ability): one row per run, dry or applied. It keeps
# the mailbox address as a string, not a key to google_connections, so the
# record outlives a disconnect. It stores the Gmail query and the counts,
# never a message id, subject or body. A new table: no existing row is read
# or written, and no data step is owed.
class CreateGmailChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :gmail_changes do |t|
      t.string :mailbox, null: false
      t.string :action, null: false
      t.text :query
      t.string :label
      t.integer :matched_count, null: false, default: 0
      t.integer :changed_count, null: false, default: 0
      t.boolean :applied, null: false, default: false
      t.string :requested_by, null: false
      t.text :error
      t.timestamps
    end
    add_index :gmail_changes, %i[mailbox created_at]
    add_check_constraint :gmail_changes,
                         "action IN ('read', 'unread', 'archive', 'inbox', 'spam', 'not_spam', 'label', 'unlabel', 'move', 'filter')",
                         name: "gmail_changes_action_known"
  end
end
