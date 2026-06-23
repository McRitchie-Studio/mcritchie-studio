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
end
