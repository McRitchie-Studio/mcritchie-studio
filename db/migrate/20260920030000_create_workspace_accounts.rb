# One row per Google Workspace we hold agentic access to.
#
# THE SAFETY PROPERTY THIS TABLE CARRIES. Domain-wide delegation cannot be
# narrowed at the grant: it authorizes impersonation of ANY user in a domain,
# and the CALLING CODE chooses whose mailbox it opens. That used to be held by
# pinning one subject in a frozen constant. Going multi-tenant turns the subject
# into data, so the guard becomes this table: Workspace::Credentials refuses to
# impersonate a subject that is not a registered, ACTIVE row here. A typo
# reaches nothing, and the set of domains this system can touch is one query.
class CreateWorkspaceAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_accounts do |t|
      t.string :domain, null: false
      # Defaults to team@<domain> — the house convention — and is validated to
      # belong to THIS row's domain, so one client's row can never be pointed
      # at another's mailbox.
      t.string :subject, null: false
      t.string :name
      t.string :entity
      t.string :status, null: false, default: "pending"  # pending | active | revoked
      t.datetime :delegation_verified_at
      t.string :last_check_error
      t.jsonb :scopes, null: false, default: []
      t.text :notes
      t.timestamps
    end
    add_index :workspace_accounts, :domain, unique: true
    add_index :workspace_accounts, :subject, unique: true

    # A folder is always walked AS a named subject, never as an implicit global
    # one. Nullable so existing rows survive; the walker refuses without it.
    add_reference :knowledge_sources, :workspace_account, foreign_key: true, null: true
  end
end
