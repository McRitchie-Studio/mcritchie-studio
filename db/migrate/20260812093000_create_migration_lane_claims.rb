# frozen_string_literal: true

# The durable `backend_migration` lane claim.
#
# The lane previously existed only as a Postgres SESSION advisory lock
# (Task.try_acquire_migration_lane). That mechanism cannot back a lane that
# agents actually operate: bin/task is an HTTP client with no database
# connection, and a lock taken inside a web request rides the POOLED connection
# after the response — so it neither survives the caller nor releases
# predictably. Worse, advisory locks are re-entrant per connection, so two
# requests landing on one pooled connection would BOTH be granted the lane.
#
# A lane that grants twice is worse than no lane, so the claim becomes a row:
# one row per lane, unique-indexed, taken under SELECT … FOR UPDATE. The unique
# index is the enforcer of "one Dev at a time"; the lease columns (mirroring
# task_review_claims / release_conductor_claims) let a crashed holder's claim
# lapse instead of wedging the lane forever.
class CreateMigrationLaneClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :migration_lane_claims do |t|
      # The lane key (Task::MIGRATION_LANE == "backend_migration"). Unique: this
      # is what makes the lane single-flight, so a second holder is impossible at
      # the DATABASE level rather than by agreement between callers.
      t.string :lane, null: false

      # Which task holds the lane — the operator-facing answer to "who do I chat
      # for an ETA?" (exclusive-lanes.md tells a refused Dev to do exactly that).
      t.string :task_slug
      t.string :holder_agent
      t.string :holder_label

      # The live-instance lease, identical in shape to task_review_claims so the
      # pure ClaimLease math judges it the same way.
      t.string   :claimed_session
      t.string   :claim_nonce
      t.datetime :acquired_at
      t.datetime :claim_expires_at

      t.timestamps
    end

    add_index :migration_lane_claims, :lane, unique: true
  end
end
