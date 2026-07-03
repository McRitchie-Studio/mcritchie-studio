# frozen_string_literal: true

# The learning-loop DevOps epic ("Move release assembly to Steffon") needs a
# durable, git-location field ORTHOGONAL to `stage` (the board position) so an
# interrupted assemble/deploy heartbeat can contextualize itself from state
# instead of guessing:
#   nil       — not merged anywhere (submitted / reviewed)
#   "release" — merged onto the release branch (going through QA)
#   "main"    — fast-forwarded into main (going through prod deploy)
# This migration is the additive foundation; nullable, no default change to
# existing rows (they read as `nil` = not-yet-merged, which is correct — the
# field only matters once a task rides a release).
class AddMergedToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :merged, :string
  end
end
