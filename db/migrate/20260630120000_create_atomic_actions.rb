class CreateAtomicActions < ActiveRecord::Migration[8.1]
  # Forward-only atomic trajectory capture — ONE row per agent action, written
  # going forward by AtomicAction.capture. The finest-grain spine beneath the
  # coarse TaskEvent stage timeline: where TaskEvent records a completed stage
  # CHANGE, an AtomicAction records a single read/edit/bash/verify/delegate step
  # within that stage. No historical backfill — capture begins at deploy.
  #
  # Mirrors the TaskEvent usage columns (model/tokens/cost) so per-action credit
  # assignment can roll up to the same attribution the stage spine carries.
  def change
    create_table :atomic_actions do |t|
      t.string   :task_slug                                   # slug FK to tasks; null for PRE-task actions (boot/intake)
      t.string   :session_id, null: false                     # the session whose trajectory this action belongs to
      t.string   :mascot                                      # session/task Pokémon slug; null when not yet drawn
      t.integer  :seq, null: false, default: 0                # position in the session trajectory (0-based)
      t.string   :kind, null: false                           # action type: read | edit | bash | verify | delegate | …
      t.string   :event_slug                                  # short human label of the action; null until distilled
      t.string   :result_slug                                 # short human label of the outcome; null until distilled
      t.text     :input                                       # the action's input (prompt / command / args)
      t.text     :output                                      # the action's output (result / stdout / diff)
      t.string   :outcome, null: false, default: "pending"    # ok | error | pending
      t.string   :model                                       # LLM model that produced the action; null for board/harness
      t.integer  :tokens_in,  null: false, default: 0
      t.integer  :tokens_out, null: false, default: 0
      t.decimal  :cost, precision: 10, scale: 4, null: false, default: 0
      t.string   :stage                                       # coarse task stage at capture time; null pre-task
      t.string   :actor, null: false, default: "agent"        # harness | agent | board | human
      t.boolean  :feedback_anchor, null: false, default: false # decision/recovery point where located feedback can attach
      t.datetime :occurred_at, null: false
      t.integer  :duration_ms                                 # wall-clock duration of the action; null when unknown
      t.timestamps
    end

    add_index :atomic_actions, [:session_id, :seq]
    add_index :atomic_actions, [:task_slug, :seq]
    add_index :atomic_actions, :occurred_at
    add_index :atomic_actions, :feedback_anchor
  end
end
