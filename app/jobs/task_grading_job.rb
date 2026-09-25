# frozen_string_literal: true

# Grades a task the moment it ships (Insights::TaskGrader) — enqueued by Task's
# after_commit on the `→ shipped` transition, so the grade reads committed facts and
# never runs inside the ship.
#
# Backend discipline — best-effort, never crash: a failure is captured to ErrorLog
# and NOT re-raised, so ApplicationJob's retry_on cannot storm on a persistent
# grading bug. The grader is idempotent (one TaskGrade per task, unique index), so
# the backfill task re-grades anything a swallowed run missed.
class TaskGradingJob < ApplicationJob
  def perform(task_slug)
    Insights::TaskGrader.grade!(task_slug)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target_name = task_slug
    log.save!
  end
end
