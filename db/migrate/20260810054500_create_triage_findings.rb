# The findings TRIAGE inbox — where agent-discovered follow-ups land INSTEAD of
# becoming board tasks. A finding costs nothing sitting here; a task costs a
# worktree, a review, and a release slot. Only an operator promote mints a task
# (stamped in promoted_task_slug, a slug-FK like the task spines).
class CreateTriageFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :triage_findings do |t|
      t.string :slug, null: false
      t.string :title, null: false
      t.text :body
      t.string :source
      t.string :repo
      t.string :status, null: false, default: "open"
      t.string :promoted_task_slug
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :triage_findings, :slug, unique: true
    add_index :triage_findings, :status
  end
end
