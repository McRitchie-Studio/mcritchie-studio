# frozen_string_literal: true

# The `backend_migration` exclusive lane is deleted (devops-v3 piece 4b-ii-b).
# Its protection is the duplicate-migration collision check that bin/dor-check and
# bin/ship run (bin/lib/migration_collision.rb), which stays. tasks.requires_migration
# stays too, as a plain flag.
#
# Reversible: `down` recreates the table exactly as 20260812093000 made it.
class DropMigrationLaneClaims < ActiveRecord::Migration[8.1]
  def change
    drop_table :migration_lane_claims do |t|
      t.string :lane, null: false

      t.string :task_slug
      t.string :holder_agent
      t.string :holder_label

      t.string   :claimed_session
      t.string   :claim_nonce
      t.datetime :acquired_at
      t.datetime :claim_expires_at

      t.timestamps

      t.index :lane, unique: true
    end
  end
end
