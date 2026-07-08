# Attempt-aware gate-run log — one row per ATTEMPT at a named testing gate
# (GateRun::GATES: G1 Cert → G2 Review lanes → G3 Candidate → G4 Ship) on a task
# or release. Unlike the releases' first-write-wins stage stamps, retries are
# first-class here: a failed attempt closes (finished_at + success=false) and the
# re-run opens attempt n+1, so repeated QA/cert failures stop collapsing into one
# invisible window. The partial unique index is the concurrency backstop: at most
# ONE in-flight attempt per (subject, gate) — racing openers converge on one row.
class CreateGateRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :gate_runs do |t|
      t.string   :subject_type, null: false # "task" | "release" (slug-FK polymorphism)
      t.string   :subject_slug, null: false
      t.string   :key,          null: false # GateRun::KEYS (g1_cert … g4_ship)
      t.integer  :attempt,      null: false
      t.datetime :started_at,   null: false
      t.datetime :finished_at                # nil = in-flight
      t.boolean  :success                    # nil = in-flight; true/false once closed
      t.jsonb    :sops,     null: false, default: [] # [{sop, cmd, tier, result, duration_ms, at}]
      t.string   :actor
      t.string   :source
      t.jsonb    :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :gate_runs, %i[subject_type subject_slug key attempt], unique: true,
              name: "index_gate_runs_on_subject_key_attempt"
    add_index :gate_runs, %i[subject_type subject_slug key], unique: true,
              where: "finished_at IS NULL", name: "index_gate_runs_one_open_per_gate"
    add_index :gate_runs, %i[subject_slug started_at]
  end
end
