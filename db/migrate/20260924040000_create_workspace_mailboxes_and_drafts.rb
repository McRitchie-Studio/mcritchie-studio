# frozen_string_literal: true

# Named mailboxes inside a workspace, and the log of every draft written as one.
#
# `workspace_accounts` allows exactly ONE address per domain (its `subject`,
# team@ by convention). Drafting needs more — alex@ in every client domain, and
# later the admins' own addresses — so the allow-list grows a child table rather
# than loosening the one-row-per-domain rule the Drive walker relies on.
#
# Both tables carry the ADDRESS as a string, not only a foreign key. That is the
# acquisition handoff: a workspace's rows export as a file that reads on its own,
# with no ids that mean anything only inside this database.
class CreateWorkspaceMailboxesAndDrafts < ActiveRecord::Migration[8.0]
  def change
    create_table :workspace_mailboxes do |t|
      t.references :workspace_account, null: false, foreign_key: true
      t.string :address, null: false
      t.string :status, null: false, default: "pending"
      t.text :signature
      t.datetime :verified_at
      t.string :last_check_error
      t.text :notes
      t.timestamps
    end
    add_index :workspace_mailboxes, :address, unique: true

    create_table :mailbox_drafts do |t|
      t.references :workspace_mailbox, null: false, foreign_key: true
      t.string :mailbox_address, null: false
      t.string :drafted_by, null: false
      t.string :gmail_draft_id, null: false
      t.string :gmail_message_id
      t.string :gmail_thread_id
      t.string :subject
      t.string :recipients
      t.timestamps
    end
    add_index :mailbox_drafts, :mailbox_address
  end
end
