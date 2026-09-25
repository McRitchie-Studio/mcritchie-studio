# frozen_string_literal: true

# Xan's ONE grade of a shipped task — the learning loop baked into the devops flow
# (devops-v3 piece 6; docs/agents/system/devops-v3-design.md §9).
#
# Written by Insights::TaskGrader when a task reaches `shipped`, from facts already
# on the board (size forecast vs actual, bounces, gate failures, cycle time, lines,
# cost). No LLM call. The row exists for EVERY graded task, so "nothing to learn"
# is a recorded verdict rather than an absence, and the unique task_slug index is
# what makes the grade happen once — a racing job or a re-run backfill loses on
# the index instead of writing a second learning.
#
# A learning, when one is written, lives in three places that point at each other:
# this row (`learning`), the task note it posted (`note_activity_slug`, an Activity
# of type comment with metadata kind "learning"), and the banked ActionGrade that
# carries it into the session-start insight feed (`action_grade_id`).
class TaskGrade < ApplicationRecord
  LEARNING = "learning"
  NOTHING_TO_LEARN = "nothing_to_learn"
  VERDICTS = [LEARNING, NOTHING_TO_LEARN].freeze

  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true, inverse_of: :task_grade
  belongs_to :action_grade, optional: true
  belongs_to :note_activity, class_name: "Activity", foreign_key: :note_activity_slug,
                             primary_key: :slug, optional: true

  validates :task_slug, presence: true, uniqueness: true
  validates :verdict, inclusion: { in: VERDICTS }
  validates :graded_at, presence: true
  validates :learning, presence: true, if: :learning?
  validates :learning, absence: true, unless: :learning?

  scope :learnings, -> { where(verdict: LEARNING) }

  def learning?
    verdict == LEARNING
  end
end
