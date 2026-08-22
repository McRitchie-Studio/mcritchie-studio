module Cert
  # Batches the board's local-check lookups, mirroring Ci::ProgressReader: the
  # board preloads ONE map for every card it is about to render, and a single-card
  # Turbo re-render falls back to a per-task read. Without the batch this would be
  # a GateRun query per card on a board that renders dozens.
  class LocalCheckReader
    # Only `building` tasks can be inside a local cert, and only until the PR
    # exists — once `bin/ship` opens it, the PR CI meter takes the slot over. The
    # controller applies the stage/PR filter; this reader answers the narrower
    # question of which of those slugs has an attempt open.
    def for_tasks(tasks, now: Time.current)
      slugs = Array(tasks).map { |task| task.slug.to_s }.reject(&:empty?)
      return {} if slugs.empty?

      runs = GateRun
        .where(subject_type: "task", subject_slug: slugs, key: "g1_cert")
        .in_flight
        .order(started_at: :desc, id: :desc)

      runs.each_with_object({}) do |run, map|
        # Newest attempt wins. A partial unique index (index_gate_runs_one_open_per_gate)
        # already forbids two in-flight attempts on one gate, so this orders against
        # the case that DOES happen: a failed cert closes and the re-run opens
        # attempt n+1, and the card must follow the live one.
        next if map.key?(run.subject_slug)

        check = LocalCheck.from_gate_run(run, now: now)
        map[run.subject_slug] = check if check
      end
    end

    def for_task(task, now: Time.current)
      return nil if task.blank?

      for_tasks([task], now: now)[task.slug.to_s]
    end
  end
end
