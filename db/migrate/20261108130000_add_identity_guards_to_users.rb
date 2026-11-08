# Two database guards on the account primitive (database audit 2026-11-07, P1):
#
# 1. A unique (provider, uid) pair. Studio::OmniauthUser finds an account by
#    that pair and settles a concurrent-callback race by rescuing
#    RecordNotUnique; without this index the second callback creates a twin
#    account instead of raising. Every satellite already has it. It is partial
#    (provider IS NOT NULL) so magic-link accounts, which have neither, stay free.
# 2. `role` takes one list, User::ROLES, enforced by CHECK users_role_known and
#    NOT NULL. Before this a mistyped role saved and quietly read as non-admin.
#
# Measured before writing: production holds viewer 13 / admin 1, no NULL role
# and no duplicate pair; QA holds viewer 4 / admin 2. So the backfill below is a
# guard for desk and QA databases, and it writes no production row.
class AddIdentityGuardsToUsers < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET role = 'viewer' WHERE role IS NULL"
    change_column_null :users, :role, false
    add_check_constraint :users, "role IN ('viewer', 'admin')", name: "users_role_known"

    add_index :users, %i[provider uid], unique: true, where: "provider IS NOT NULL",
              name: "index_users_on_provider_and_uid"
  end

  def down
    remove_index :users, name: "index_users_on_provider_and_uid"
    remove_check_constraint :users, name: "users_role_known"
    change_column_null :users, :role, true
  end
end
