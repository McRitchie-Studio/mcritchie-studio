# The per-RELEASE conductor claim lease — at most one live conductor per (release,
# role), where role is `assembler` (bin/release prepare / qa-release) or `deployer`
# (bin/release ship / production-deploy). This moves the QA-assemble and prod-deploy
# locks OFF the per-ROLE devops shift (devops_shifts, one steffon/avi session at a
# time) and ONTO the RELEASE record: two claim rows per release. Because the lock
# lives on a record that TURNS OVER every release, a stale/ghost claim can never
# strand a GLOBAL lane again — the anti-stranding property the shift lease lacked.
#
# It is the role-lease (devops_shifts) one level down: lane → (release, role), the
# mirror of task_review_claims' lane → task move for the review lane. Same
# build-claim / shift-lease shape (lib/claim_lease.rb): a session + per-instance
# nonce under a TTL renewed by the run's own detached renewer. One row per
# (release_slug, role); the COMPOSITE unique index is what makes acquire an atomic
# compare-and-set (one winner per release+role).
class CreateReleaseConductorClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :release_conductor_claims do |t|
      t.string   :release_slug, null: false     # the release under assembly/deploy (slug FK to releases.slug)
      t.string   :role,         null: false      # assembler (prepare) | deployer (ship)
      t.string   :claimed_session                # the conductor's agent session id
      t.string   :claim_nonce                    # the conductor's per-instance nonce
      t.datetime :claim_expires_at               # TTL lease; lapses when the conductor stops renewing
      t.string   :holder_label                   # human tag for the stand-down message (mascot/agent)
      t.datetime :acquired_at                     # when the CURRENT conductor took this (release, role)
      t.timestamps
    end
    # The composite unique key: exactly one row per (release, role) — the atomic CAS
    # anchor, the same guarantee task_review_claims gets from its single-column index.
    add_index :release_conductor_claims, %i[release_slug role], unique: true
  end
end
