class CreateActionGrades < ActiveRecord::Migration[8.1]
  # The grading layer over AtomicAction — the learning heartbeat's feedback.
  # Each graded action carries up to TWO rows: Alex's grade of the action, and
  # Mr. McRitchie's audit-of-Alex (the recursive verdict on Alex's grade). The
  # grader column distinguishes the two; the (atomic_action_id, grader) pair is
  # unique so an action holds at most one Alex grade and one McRitchie audit.
  #
  # The Insight Bank is the curated set of banked grades — the distilled lessons
  # that make each next agent smarter. banked/discarded are the two disposition
  # flags the drawer toggles (mutually exclusive: banking clears discard, and
  # discarding clears bank). Mirrors the prototype's a/m feedback objects
  # (sl=slug, d=disposition, lg=long-form, banked, discarded).
  def change
    create_table :action_grades do |t|
      t.references :atomic_action, null: false, foreign_key: true   # integer FK to the graded action
      t.string   :grader, null: false                               # alex | mcr — two rows: grade + audit-of-grade
      t.string   :slug, null: false                                 # 4–7 word feedback slug (NOT an identity slug)
      t.string   :disposition, null: false                          # good | not — the binary credit signal
      t.text     :long_form                                         # optional anchored lesson; null when terse
      t.boolean  :banked, null: false, default: false               # in the Insight Bank?
      t.boolean  :discarded, null: false, default: false            # explicitly set aside (not banked)
      t.timestamps
    end

    # One Alex grade + one McRitchie audit per action.
    add_index :action_grades, [:atomic_action_id, :grader], unique: true
    add_index :action_grades, :banked
  end
end
