# An agent session: one soul logged in at one tier, owned by the server. The
# bearer token an agent holds carries only this row's slug, so a revoke or an
# expiry here ends the session on its next call. A new table, so the migration
# takes no lock on anything live.
class CreateAgentSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_sessions do |t|
      t.string :slug, null: false
      # A slug from config/souls.yml.
      t.string :soul, null: false
      # admin | studio | client, validated in the model.
      t.string :tier, null: false
      # The task a studio session may write. Null for admin, whose tier is its scope.
      t.string :task_slug
      # The Claude or Codex session holding it.
      t.string :harness_session_id
      # task_claim | review_claim | operator_grant | launch_phrase | runtime_key.
      t.string :issued_by, null: false
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.string :revoked_by
      t.timestamps
    end
    add_index :agent_sessions, :slug, unique: true
    add_index :agent_sessions, %i[task_slug revoked_at]
    add_index :agent_sessions, %i[soul tier]
  end
end
