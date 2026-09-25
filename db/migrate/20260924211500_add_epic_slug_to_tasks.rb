# frozen_string_literal: true

# The connective tissue between an epic and its tasks (DevOps v3, design §3 —
# docs/agents/system/devops-v3-design.md).
#
# An epic is a plan a focus session holds; it is NOT a card, and there is
# deliberately no Epic model or plan store behind this column. The board gets
# exactly one optional field: the epic's slug on the task, so the card can wear an
# epic chip beside its task-slug chip and clicking it filters the board to that
# epic (`/tasks?epic=<slug>`).
#
# A top-level COLUMN rather than a `metadata.devops` key, for the same reason
# `dependencies` and `release_slug` are: the boards filter on it in SQL, so it
# needs an index a jsonb key cannot cheaply carry, and a devops write to the
# same name is refused (Task::DEVOPS_COLUMN_KEYS) so the two stores can never
# diverge. Nullable — most tasks belong to no epic — and indexed, because the
# filter is the whole point of the field.
class AddEpicSlugToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :epic_slug, :string
    add_index :tasks, :epic_slug
  end
end
