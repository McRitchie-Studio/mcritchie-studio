# frozen_string_literal: true

# The learning loop's per-task grade (devops-v3 piece 6): ONE row per shipped task,
# computed once from facts already on the board. Keyed by the task's slug (the
# ecosystem's slug-FK convention); the unique index is what makes "graded once"
# hold under a racing job or a re-run backfill.
class CreateTaskGrades < ActiveRecord::Migration[8.0]
  def change
    create_table :task_grades do |t|
      t.string :task_slug, null: false
      t.string :grader, null: false, default: "xan"
      t.string :verdict, null: false
      t.jsonb :facts, null: false, default: {}
      t.jsonb :tripped, null: false, default: []
      t.text :learning
      t.string :note_activity_slug
      t.bigint :action_grade_id
      t.datetime :graded_at, null: false
      t.timestamps
    end
    add_index :task_grades, :task_slug, unique: true
    add_index :task_grades, :verdict
  end
end
