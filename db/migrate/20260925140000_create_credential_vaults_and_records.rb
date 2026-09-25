# frozen_string_literal: true

# Records OF credentials — never the credentials. A vault row names a 1Password
# vault and the client workspace it serves; a record row names one item in it:
# what it is, who consumes it, what its scope permits. Neither table has a
# column that could hold a secret value, and CredentialRecord refuses text that
# looks like one. The value itself stays in 1Password.
#
# Slug-keyed like the rest of the hub: records point at their vault by the
# vault's slug (its 1Password name), and a vault points at its client by the
# WorkspaceAccount's domain, so a vault can be recorded before the workspace is.
class CreateCredentialVaultsAndRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :credential_vaults do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :entity, null: false
      t.string :lane, null: false
      t.string :icon_scope
      t.string :workspace_domain
      t.string :status, null: false, default: "active"
      t.text :purpose
      t.timestamps
    end
    add_index :credential_vaults, :slug, unique: true
    add_index :credential_vaults, :workspace_domain

    create_table :credential_records do |t|
      t.string :title, null: false
      t.string :credential_vault_slug, null: false
      t.string :service, null: false
      t.string :category
      t.string :url
      t.string :used_by
      t.text :scope_summary
      t.string :status, null: false, default: "filed"
      t.text :notes
      t.timestamps
    end
    add_index :credential_records, [ :credential_vault_slug, :title ], unique: true
    add_index :credential_records, :status
  end
end
