# The durable ARMED MERGE — a reviewer's already-formed, already-recorded
# merge-ready verdict, written down so it can finish executing after the
# reviewer's process is gone.
#
# WHY (measured seven times on 2026-08-10/11): a reviewer completes its review,
# records a correct merge-ready verdict, waits on a CI lane, and its process ends
# before it can merge. The DECISION survived — it was on the task record — but the
# EXECUTION was lost, and a human merged all seven by hand. One reviewer stopped
# with 3 of 4 lanes green; the fourth settled eighty seconds later.
#
# This table holds nothing a reviewer has not already decided. It is a recorded
# instruction ("merge THIS pr at THIS sha, authorised by THIS verdict"), never a
# judgement of its own — see ReviewPendingAction and Review::PendingActionExecutor.
class CreateReviewPendingActions < ActiveRecord::Migration[8.1]
  def change
    create_table :review_pending_actions do |t|
      # Slug-based FK to tasks, the convention everywhere in this schema.
      t.string   :task_slug,   null: false
      t.string   :action,      null: false, default: "merge_to_accepted"

      # The PR the action targets, pinned at arm time rather than re-derived from
      # the task at execution time: the instruction must describe the same PR the
      # reviewer read, even if the task record is edited afterwards.
      t.string   :repo,        null: false            # "McRitchie-Studio/mcritchie-studio"
      t.integer  :pr_number,   null: false
      t.string   :pr_url
      t.string   :base_branch, null: false, default: "accepted"
      t.string   :merge_method, null: false, default: "merge"

      # THE PIN. The verdict described this tree and no other. A head that moved
      # refuses the action outright — it was never reviewed.
      t.string   :head_sha,    null: false

      # The authorising verdict. `verdict_activity_id` points at the recorded
      # scout report; without one there is no decision to execute.
      t.string   :verdict,     null: false
      t.bigint   :verdict_activity_id
      t.string   :authorized_by
      t.datetime :verdict_recorded_at

      # pending → executed | expired | refused | disarmed
      t.string   :state,       null: false, default: "pending"
      # Fail-closed by clock: an action nobody could execute in time is dropped,
      # never executed late against a world that has moved on.
      t.datetime :expires_at,  null: false
      t.datetime :executed_at
      t.datetime :last_attempted_at
      t.integer  :attempts,    null: false, default: 0
      t.string   :merge_sha
      t.text     :outcome_reason
      t.jsonb    :metadata,    null: false, default: {}

      t.timestamps
    end

    add_index :review_pending_actions, :task_slug
    # The webhook trigger's lookup key: a settled CI run names its repo + head_sha,
    # and that pair selects exactly the actions pinned to that tree.
    add_index :review_pending_actions, [:repo, :head_sha]
    add_index :review_pending_actions, [:state, :expires_at]
    # At most ONE live armed action per task. A re-arm supersedes the prior one
    # (see ReviewPendingAction.arm!) rather than stacking a second merge order.
    add_index :review_pending_actions, :task_slug,
              unique: true,
              where: "state = 'pending'",
              name: "index_review_pending_actions_on_live_task_slug"
  end
end
