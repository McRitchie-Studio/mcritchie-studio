# The dream loop (docs/agents/modules/dream.md, Act 4): what a session's wrap
# records about the dreams that fired in it, and Alex's one-click retirements.
#
# dream_grades   one grade (0, 1 or 2) per dream per session, only for a dream
#                that fired in that session; agent-written data, never an approval.
# dream_swaps    at most one swap proposal per session: an add, an in-and-out, or
#                "no swap" (both sides blank). Alex approves it on /dreams.
# dream_retirements  Alex's retirement of an approved dream, waiting for the next
#                batch task (`bin/dream apply-approvals`) to delete the file;
#                applied_at is stamped once the deployed bank no longer holds it.
#
# A dream is keyed by its bank home and file slug, as dream_approvals keys it.
class CreateDreamLoopTables < ActiveRecord::Migration[8.1]
  def change
    create_table :dream_grades do |t|
      t.string :dream_slug, null: false
      t.integer :score, null: false
      t.string :decision, null: false
      t.string :session_id, null: false
      t.bigint :agent_action_id
      t.string :task_slug
      t.string :mascot
      t.timestamps
    end
    add_index :dream_grades, [ :session_id, :dream_slug ], unique: true
    add_index :dream_grades, [ :dream_slug, :created_at ]
    add_index :dream_grades, :created_at
    add_check_constraint :dream_grades, "score BETWEEN 0 AND 2", name: "dream_grades_score_range"

    create_table :dream_swaps do |t|
      t.string :session_id, null: false
      t.string :layer
      t.string :in_home
      t.string :in_slug
      t.string :out_home
      t.string :out_slug
      t.string :reason, null: false
      t.string :task_slug
      t.string :mascot
      t.datetime :approved_at
      t.string :approved_by_slug
      t.timestamps
    end
    add_index :dream_swaps, :session_id, unique: true
    add_index :dream_swaps, :approved_at
    add_index :dream_swaps, :created_at
    add_foreign_key :dream_swaps, :users, column: :approved_by_slug, primary_key: :slug,
                                          on_update: :cascade, on_delete: :nullify

    create_table :dream_retirements do |t|
      t.string :dream_home, null: false
      t.string :dream_slug, null: false
      t.string :retired_by_slug
      t.datetime :retired_at, null: false
      t.datetime :applied_at
      t.references :dream_swap, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :dream_retirements, [ :dream_home, :dream_slug ], unique: true
    add_index :dream_retirements, :applied_at
    add_foreign_key :dream_retirements, :users, column: :retired_by_slug, primary_key: :slug,
                                                on_update: :cascade, on_delete: :nullify
  end
end
