# A satellite app's own bearer credential to a hub API (task hub-agent-chat-api;
# epic .agents/epics/agent-chat-primitive.md). The hub keeps only the SHA-256
# digest of the secret; the secret is printed once by `bin/rails
# app_credentials:mint` for filing into 1Password (`apps.<slug>.<purpose>`) and
# the app's Heroku config. One live row per (app, purpose): minting again
# revokes the old one.
#
# app_slug is not a foreign key to apps: a satellite that calls the hub (alex.build)
# need not have an App row on the board, and the allow-list that decides what it
# may reach is config/agent_routes.yml, not this table.
class CreateAppCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :app_credentials do |t|
      t.string :app_slug, null: false
      t.string :purpose, null: false
      t.string :token_digest, null: false
      t.string :label
      t.string :issued_by
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.string :revoked_by
      t.timestamps
    end
    add_index :app_credentials, :token_digest, unique: true
    # One LIVE credential per app per purpose: AppCredential.issue! revokes the old
    # one first, and two mints racing cannot both stand.
    add_index :app_credentials, %i[app_slug purpose], unique: true, where: "revoked_at IS NULL",
                                                      name: "index_app_credentials_one_live_per_app_purpose"
    add_check_constraint :app_credentials, "purpose IN ('agent-chat')", name: "app_credentials_purpose_known"
  end
end
