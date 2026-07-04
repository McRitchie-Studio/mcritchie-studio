class AddSourceActivityToActionGrades < ActiveRecord::Migration[8.1]
  # Provenance for a MACHINE-SEEDED grade candidate: the qa_feedback Activity (a
  # QA block) it was mined from. A block that goes blocked -> resolved is a
  # PRE-LABELED failure case, so Insights::BlockMiner seeds a disposition:"not"
  # ActionGrade candidate tying the block's feedback text to the span that caused
  # the defect. Human grades (the drawer / the bearer CLI) leave this NULL, so the
  # column also DISTINGUISHES mined candidates from hand-authored grades.
  #
  # Slug FK (the ecosystem convention — activities.slug, not the integer id). The
  # UNIQUE partial index is the idempotency spine: at most ONE candidate per block,
  # forever, so re-running the miner (or a racing job) never duplicates a candidate.
  def change
    add_column :action_grades, :source_activity_slug, :string

    add_index :action_grades, :source_activity_slug, unique: true,
              where: "source_activity_slug IS NOT NULL",
              name: "index_action_grades_on_source_activity_slug"
  end
end
