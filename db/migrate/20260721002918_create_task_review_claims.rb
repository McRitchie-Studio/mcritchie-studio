# The per-TASK review claim lease — at most one live REVIEWER per submitted task,
# so MANY pr-review sessions can run in parallel and each simply SKIPS a task
# already under live review. This is the role-lease (devops_shifts) one level down:
# lane → task. Mirrors the build-claim / shift-lease shape (lib/claim_lease.rb): a
# session + per-instance nonce under a TTL renewed by the review's own renewer. One
# row per task_slug; the unique index is what makes acquire an atomic compare-and-set.
class CreateTaskReviewClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :task_review_claims do |t|
      t.string   :task_slug, null: false        # the task under review (slug FK to tasks.slug)
      t.string   :claimed_session                # the reviewer's agent session id
      t.string   :claim_nonce                    # the reviewer's per-instance nonce
      t.datetime :claim_expires_at               # TTL lease; lapses when the reviewer stops renewing
      t.string   :holder_label                   # human tag for the skip message (mascot/agent)
      t.datetime :acquired_at                     # when the CURRENT reviewer took the task
      t.timestamps
    end
    add_index :task_review_claims, :task_slug, unique: true
  end
end
