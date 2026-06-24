# frozen_string_literal: true

# Adds `kind` to the append-only task_events spine so it can carry INTENT rows
# (an agent STARTING a stage's work — the live, in-progress signal) alongside the
# existing TRANSITION rows (a completed stage change). One unified event log: the
# consolidated timeline renders both in order, and the board's live ticker reads
# OPEN intents (an intent whose target stage has not produced its transition yet).
#
# Every existing row is a transition, so the default backfills them correctly and
# the duration spine (seconds_in_from, measured between TRANSITIONS) is untouched.
class AddKindToTaskEvents < ActiveRecord::Migration[7.2]
  def change
    add_column :task_events, :kind, :string, null: false, default: "transition"
    # Intents are read per-task ("the open intent for this task's next stage"), so
    # index the slug+kind pair the helper filters on.
    add_index :task_events, %i[task_slug kind]
  end
end
