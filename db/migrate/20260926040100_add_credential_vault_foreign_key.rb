# frozen_string_literal: true

# A record's vault is enforced by the DATABASE, not only by the model's
# `dependent: :restrict_with_exception` — which a delete_all or a raw SQL
# delete walks straight past. Slug-keyed, against the unique index on
# credential_vaults.slug. (Review follow-up on onepass-vault-icons.)
class AddCredentialVaultForeignKey < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :credential_records, :credential_vaults,
                    column: :credential_vault_slug, primary_key: :slug
  end
end
