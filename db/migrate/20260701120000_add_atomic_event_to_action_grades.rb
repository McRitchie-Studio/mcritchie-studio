class AddAtomicEventToActionGrades < ActiveRecord::Migration[8.1]
  # A grade can now target a narrated AtomicEvent SPAN, not only a raw
  # AtomicAction. This is an ADDITIVE dual-FK (not a polymorphic rewrite): the
  # working action-grading path is untouched, we simply add a second, mutually
  # exclusive target. The XOR (exactly one target) lives in the model; the DB
  # keeps each FK independently unique per grader.
  def change
    # Relax the action FK to nullable — an event-targeted grade carries a NULL
    # atomic_action_id (and vice-versa). Existing action grades keep their FK.
    change_column_null :action_grades, :atomic_action_id, true

    # The narrated SPAN a grade can target instead of a raw action. Nullify on
    # delete (not cascade) so removing a span never destroys the grades that
    # framed it — mirrors AtomicEvent#atomic_actions (on_delete: :nullify).
    add_reference :action_grades, :atomic_event, null: true, index: true,
                  foreign_key: { on_delete: :nullify }

    # One grade per (event, grader) — the span-level mirror of the existing
    # (atomic_action_id, grader) unique index. Partial so it applies only to
    # event-targeted rows (Postgres already treats the NULL atomic_event_id of an
    # action grade as distinct, but the WHERE keeps the intent explicit).
    add_index :action_grades, [:atomic_event_id, :grader], unique: true,
              where: "atomic_event_id IS NOT NULL",
              name: "index_action_grades_on_atomic_event_id_and_grader"
  end
end
