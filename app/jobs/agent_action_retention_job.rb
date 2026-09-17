# Retention for the agent_actions telemetry log: deletes rows OLDER than 45 days.
#
# THE RULE is Mr. McRitchie's, 2026-09-16, verbatim: "For deleting the rows I only
# want to delete rows older than 45 days old." It applies to agent_actions ONLY. A row
# 45 days old or newer is never touched: the predicate is a strict `occurred_at <
# cutoff`, and the cutoff is taken ONCE per run, so a long run cannot creep forward.
#
# THE CLOCK IS occurred_at, not created_at. occurred_at is when the action happened,
# it is NOT NULL, and it carries its own index (index_agent_actions_on_occurred_at), so
# every batch walks that index instead of scanning a ~400k-row table. Measured on
# production 2026-09-17: no row's occurred_at is more than a day from its created_at,
# so the choice moves no row today; it is the semantically right clock, and the cheap one.
#
# TWO KINDS OF OLD ROW ARE KEPT, because something durable still reads them:
#
#   * A GRADED action — any row an ActionGrade targets (agent_action_id). A banked grade
#     is the Insight Bank, which the SessionStart feed serves to every fresh session;
#     AgentAction `has_many :action_grades, dependent: :destroy`, so deleting the action
#     would silently delete the lesson. (A raw DELETE trips the action_grades FK
#     anyway.) The check is NOT EXISTS, never NOT IN: activity-target grades carry a
#     NULL agent_action_id, and one NULL in a NOT IN list matches nothing, which would
#     quietly turn the whole job into a no-op.
#   * A CI test-scope action — event_slug in Task::TestingPhases::CI_SCOPES. Those rows
#     are the source of the CI phase that Task::TestingPhases denormalizes onto the task
#     row, and that projection is REBUILT from source on every stage move, TaskEvent,
#     GateRun and VERSION-bump backfill. Delete the rows and the next rebuild blanks the
#     CI phase for every old task, silently. The constant is shared, not copied, so
#     retiring or adding a slug there moves this guard with it. `event_slug IS NULL OR
#     NOT IN` is spelled out because a bare NOT IN drops every NULL event_slug row, which
#     is most of the table.
#
#   Measured on production 2026-09-17: 0 graded actions and 0 CI-scope actions exist, so
#   today the guard keeps nothing. It exists so a grade or a CI capture written tomorrow
#   is never the thing a retention run silently takes.
#
# SHAPE — it must be safe for a table every agent writes to constantly, and the FIRST
# production run clears the whole backlog (~100k rows):
#
#   * Small batches: one DELETE ... WHERE id IN (SELECT id ... ORDER BY occurred_at
#     LIMIT 5000) per batch. Each statement autocommits, so each transaction is one
#     short statement and the locks are row locks on rows nothing else writes.
#   * A pause between batches, and a runtime budget. A run that hits the budget stops
#     cleanly and logs the remainder; the next run resumes where it left off. Nothing
#     here needs finishing in one go.
#   * It runs on the `worker` dyno (bin/jobs), never inside a web request, and holds one
#     connection for its duration.
#   * Idempotent: a re-run, a retry, or a run killed mid-statement (that statement rolls
#     back; earlier batches stay committed) only ever deletes rows past the window.
#
# NO VACUUM FULL, NO pg_repack. A DELETE does not shrink the reported database size;
# autovacuum makes the freed space reusable inside the table, which is what stops the
# growth. Rewriting the table takes a full lock on the busiest write path on the board.
#
# Backend discipline: a failure is rescued into an ErrorLog and NOT re-raised, so
# ApplicationJob's retry_on cannot storm on a persistent fault. The next scheduled run
# covers it, and every batch already committed stays deleted.
class AgentActionRetentionJob < ApplicationJob
  queue_as :default

  RETENTION_WINDOW = 45.days
  BATCH_SIZE = 5_000
  MAX_RUNTIME_SECONDS = 600
  PAUSE_SECONDS = 0.25

  Result = Struct.new(:cutoff, :deleted, :batches, :drained, :retained, keyword_init: true)

  # The moment a row must be OLDER than to be deleted. The app runs in UTC, so this is
  # exactly 45 * 86,400 seconds, with no DST hour to gain or lose.
  def self.cutoff(now: Time.current)
    now - RETENTION_WINDOW
  end

  # Every row the job may delete: older than the cutoff AND read by nothing durable.
  # See the header for why each guard is spelled the way it is.
  def self.expired(cutoff)
    AgentAction
      .where("agent_actions.occurred_at < ?", cutoff)
      .where("agent_actions.event_slug IS NULL OR agent_actions.event_slug NOT IN (?)",
             Task::TestingPhases::CI_SCOPES)
      .where("NOT EXISTS (SELECT 1 FROM action_grades WHERE action_grades.agent_action_id = agent_actions.id)")
  end

  def perform(batch_size: BATCH_SIZE, max_runtime: MAX_RUNTIME_SECONDS, pause: PAUSE_SECONDS)
    @cutoff = self.class.cutoff
    @deleted = 0
    @batches = 0
    started = monotonic_now
    drained = false

    loop do
      count = delete_batch(batch_size)
      @batches += 1
      @deleted += count

      if count < batch_size
        drained = true
        break
      end
      break if monotonic_now - started >= max_runtime

      sleep(pause) if pause.to_f.positive?
    end

    retained = drained ? AgentAction.where("agent_actions.occurred_at < ?", @cutoff).count : nil
    result = Result.new(cutoff: @cutoff, deleted: @deleted, batches: @batches, drained: drained, retained: retained)
    Rails.logger.info(summary(result))
    result
  rescue StandardError => e
    Rails.logger.error("[AgentActionRetentionJob] stopped after deleting #{@deleted.to_i} row(s) in " \
                       "#{@batches.to_i} batch(es): #{e.class}")
    log = ErrorLog.capture!(e)
    log.target_name = "agent_actions"
    log.save!
    nil
  end

  private

  # One short, self-committing statement. The subquery re-applies the whole predicate,
  # so a row graded between batches is never in the batch that deletes.
  def delete_batch(batch_size)
    batch = self.class.expired(@cutoff).order(:occurred_at).limit(batch_size).select(:id)
    AgentAction.where(id: batch).delete_all
  end

  def summary(result)
    tail = if result.drained
             "drained; kept #{result.retained} older row(s) a grade or CI phase still reads"
           else
             "runtime budget reached; the remainder resumes next run"
           end
    "[AgentActionRetentionJob] deleted #{result.deleted} agent_actions row(s) with occurred_at < " \
      "#{result.cutoff.utc.iso8601} (older than #{RETENTION_WINDOW.inspect}) in #{result.batches} batch(es); #{tail}"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
