class CreateTaskEvents < ActiveRecord::Migration[7.2]
  # Append-only audit spine for task stage transitions. One row per stage
  # change, written deterministically from Task#record_stage_event. The
  # from/to/occurred_at/seconds_in_from columns are server-owned and exact; the
  # model/tokens/cost columns are best-effort, agent-supplied per transition and
  # null for model- or conductor-driven changes.
  def change
    create_table :task_events do |t|
      t.string   :task_slug, null: false
      t.string   :from_stage              # null on the genesis (creation) event
      t.string   :to_stage, null: false
      t.datetime :occurred_at, null: false
      t.integer  :seconds_in_from         # time spent in from_stage; null when unknown
      t.string   :source                  # cli | api | web | conductor | system
      t.string   :actor                   # agent_slug / session id / admin
      t.string   :model                   # LLM model that did the work in from_stage
      t.integer  :tokens_in
      t.integer  :tokens_out
      t.decimal  :cost, precision: 10, scale: 4
      t.jsonb    :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :task_events, [:task_slug, :occurred_at]
  end
end
