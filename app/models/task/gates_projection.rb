# frozen_string_literal: true

class Task
  # Materialized LATEST-ATTEMPT-PER-GATE snapshot — the newest GateRun for each
  # task-grain gate (G1 Cert, DoR builder, DoR review, G2a Primary, G2b Light),
  # denormalized onto the task row (gates jsonb) exactly like Task::TestingPhases.
  # A PURE function of the
  # task's gate_runs (GateRun.latest_by_key computes the read), so recompute is
  # idempotent and self-heals on a VERSION bump (see #cached_or_built). gate_runs
  # stays the source of truth; this is a read-side convenience for the tasks API.
  #
  # Release-grain gates (G3 Candidate, G4 Ship) are release-owned and inherited by
  # membership — intentionally OUT of this per-task projection (release surfaces
  # read gate_runs directly).
  module GatesProjection
    # v2: the two DoR gates (dor, dor_review) joined the task-grain set. Bumping
    # the version self-heals every cached 3-key projection on first access
    # (cached_or_built rebuilds from gate_runs on a version mismatch — no backfill).
    VERSION = 2

    # The task-grain gate keys this projection snapshots (g1_cert, dor, dor_review,
    # g2a_primary, g2b_light). Every key is always present in the map — a
    # never-attempted gate carries the all-nil row — so consumers never key-check.
    GATE_KEYS = GateRun::TASK_KEYS

    # The per-gate row keys — the operator's flat shape: the attempt ordinal, its
    # started/finished window, the verdict (nil while in flight), and the executed
    # test SOPs recorded inside the window.
    ROW_KEYS = %w[attempt started_at finished_at success sops].freeze

    module_function

    def build(task, now: Time.current)
      task = Task.find_by!(slug: task) unless task.is_a?(Task)
      latest = GateRun.latest_by_key(subject_type: "task", subject_slug: task.slug)
      {
        "cache_version" => VERSION,
        "cached_at" => now.in_time_zone.iso8601,
        "gates" => GATE_KEYS.index_with { |key| gate_row(latest[key]) }
      }
    end

    # Idempotent persist — update_columns skips validations/callbacks (no re-entrancy).
    def refresh!(task, now: Time.current)
      task = Task.find_by!(slug: task) unless task.is_a?(Task)
      projection = build(task, now: now)
      task.update_columns( # rubocop:disable Rails/SkipsModelValidations
        gates: projection,
        gates_cached_at: now.in_time_zone,
        gates_version: VERSION,
        updated_at: Time.current
      )
      projection
    end

    # Serve the cached projection when it matches the current VERSION, else recompute
    # on the fly (self-healing on a version bump — this is why no backfill is needed).
    # Never raises into a render.
    def cached_or_built(task)
      if task.gates_version == VERSION && task.gates.present?
        task.gates
      else
        build(task)
      end
    rescue StandardError => e
      Rails.logger.warn("[task-gates] projection unavailable for #{task.slug}: #{e.class}: #{e.message}")
      empty_projection
    end

    # A safe, gates-all-empty projection — returned when a live read genuinely
    # can't build (so cached_or_built NEVER re-raises into a render, honoring its
    # contract). Consumers already tolerate the all-nil row.
    def empty_projection
      {
        "cache_version" => VERSION,
        "cached_at" => nil,
        "gates" => GATE_KEYS.index_with { empty_row }
      }
    end

    # ---- row construction ------------------------------------------------------

    # One gate's snapshot: the NEWEST attempt (retries are first-class on gate_runs;
    # only the latest is denormalized here). success stays nil while in flight.
    def gate_row(run)
      return empty_row unless run

      {
        "attempt" => run.attempt,
        "started_at" => run.started_at&.iso8601,
        "finished_at" => run.finished_at&.iso8601,
        "success" => run.success,
        "sops" => run.sops || []
      }
    end

    def empty_row
      { "attempt" => nil, "started_at" => nil, "finished_at" => nil, "success" => nil, "sops" => [] }
    end
  end
end
