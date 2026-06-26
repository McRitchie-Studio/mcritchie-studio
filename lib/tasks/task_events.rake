# Best-effort helpers for task_events:backfill_usage. Historical usage is mostly
# unrecoverable (the per-transition token baseline is gone), so the backfill can
# only recover the MODEL a session used — never the token delta or cost. These
# resolve which session's transcript a past event maps to.
module TaskEventsBackfill
  module_function

  # The session id to look up a transcript for a past transition event. CLI moves
  # stamp the mover's own session id as the event ACTOR (a UUID — digits +
  # hyphens), distinct from a soul slug (lowercase letters, no digits). Prefer
  # that; else fall back to the task's recorded build-claim session
  # (devops.session_id). nil when neither is available (no transcript to find).
  def session_id_for(event)
    actor = event.actor.to_s.strip
    return actor if session_shaped?(actor)

    event.task&.devops&.dig("session_id").to_s.strip.presence
  end

  # A session id always carries a digit (a UUID / thread id); a soul slug never
  # does. Used to tell the two apart without an Agent-table lookup.
  def session_shaped?(value)
    value.present? && value.match?(/\d/)
  end
end

namespace :task_events do
  desc "Backfill TaskEvent rows for existing tasks from their stage-timestamp columns (idempotent)."
  task backfill: :environment do
    created = 0
    skipped = 0

    Task.find_each do |task|
      if task.task_events.exists?
        skipped += 1
        next
      end

      # Reconstruct a monotonic timeline from whatever stage timestamps exist.
      # This is approximate — historical bounces (e.g. blocked → building →
      # blocked) overwrote the single-slot columns and can't be recovered — so
      # every synthesized row is tagged source=system, backfilled=true.
      points = [
        ["designed",  task.created_at],
        ["building",  task.started_at],
        ["submitted", task.submitted_at],
        ["reviewed",  task.reviewed_at],
        ["assembled", task.assembled_at],
        ["shipped",   task.completed_at],
        ["blocked",   task.blocked_at],
        ["archived",  task.archived_at]
      ].select { |(_, at)| at.present? }.sort_by { |(_, at)| at }

      prev_stage = nil
      prev_at = nil
      points.each do |(stage, at)|
        task.task_events.create!(
          from_stage: prev_stage,
          to_stage: stage,
          occurred_at: at,
          seconds_in_from: prev_at && (at - prev_at).round,
          source: "system",
          metadata: { "backfilled" => true }
        )
        created += 1
        prev_stage = stage
        prev_at = at
      end
    end

    puts "task_events:backfill — created #{created} event(s), skipped #{skipped} task(s) with existing events."
  end

  desc "Best-effort backfill of MODEL usage on past TaskEvents from session transcripts (logs filled vs skipped)."
  task backfill_usage: :environment do
    require Rails.root.join("lib/agent_session_usage").to_s

    root = AgentSessionUsage.default_root
    filled = 0
    skipped = Hash.new(0)

    # Only TRANSITION rows carry usage; intents + genesis are usageless by design
    # (see Task#record_intent_event / #record_genesis_event). Never overwrite a
    # row that already has usage — a real captured delta beats a re-derived model.
    TaskEvent.transitions.find_each do |event|
      if event.usage?
        skipped[:already_had_usage] += 1
        next
      end

      sid = TaskEventsBackfill.session_id_for(event)
      if sid.blank?
        skipped[:no_session] += 1
        next
      end

      path = AgentSessionUsage.transcript_for(sid, root)
      if path.nil?
        skipped[:no_transcript] += 1
        next
      end

      _totals, model = AgentSessionUsage.sum_usage(path)
      if model.blank?
        skipped[:no_model] += 1
        next
      end

      # Recover the MODEL only — the per-transition token DELTA is unrecoverable
      # for history (no stored baseline), so we never fabricate tokens/cost. Flag
      # the row so the timeline can mark it approximate. This is the one place a
      # TaskEvent is updated post-create; it fires no after_update broadcast.
      event.update!(model: model, metadata: event.metadata.merge("usage_backfilled" => true))
      filled += 1
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = event.task
      log.target_name = event.task_slug
      log.save!
      skipped[:errored] += 1
    end

    puts "task_events:backfill_usage — filled #{filled} event(s) with a model; skipped " \
         "#{skipped[:already_had_usage]} already-had-usage, #{skipped[:no_session]} no-session, " \
         "#{skipped[:no_transcript]} no-transcript, #{skipped[:no_model]} no-model-in-transcript, " \
         "#{skipped[:errored]} errored (logged to ErrorLog)."
    puts "  NOTE: token deltas + cost are NOT recoverable for history and were not fabricated."
  end
end
