# The devops SHIFT lease — at most one live holder per lane (a role: avi / steffon /
# alex), so two same-role conductor sessions can't collide. Mirrors the build-claim
# lease shape (lib/claim_lease.rb): a session + per-instance nonce under a TTL
# renewed by the heartbeat. One row per lane; the unique index is what makes acquire
# an atomic compare-and-set.
class CreateDevopsShifts < ActiveRecord::Migration[8.1]
  def change
    create_table :devops_shifts do |t|
      t.string   :lane, null: false            # the role/shift key: avi | steffon | alex
      t.string   :claimed_session               # the holder's agent session id
      t.string   :claim_nonce                   # the holder's per-instance nonce
      t.datetime :claim_expires_at              # TTL lease; lapses when the holder stops renewing
      t.string   :holder_label                  # human tag for the step-down message (mascot/agent)
      t.datetime :acquired_at                    # when the CURRENT holder took the shift
      t.timestamps
    end
    add_index :devops_shifts, :lane, unique: true
  end
end
