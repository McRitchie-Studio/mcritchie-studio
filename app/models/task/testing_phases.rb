# frozen_string_literal: true

class Task
  # Materialized per-task TESTING-PHASE durations — a start→complete window for each
  # phase, denormalized onto the task row (testing_phases jsonb) exactly like
  # Release::DurationCache denormalizes onto releases. A PURE function of the task's
  # append-only TaskEvents + approval devops stamps + CI test-scope AgentActions, so
  # recompute is idempotent and self-heals on a VERSION bump (see #cached_or_built).
  #
  # The five phases are TASK-OWNED (individual to the branch, all done by `reviewed`).
  # Release-owned phases (QA, production) are release-grain and inherited by membership
  # — intentionally OUT of this per-task projection.
  module TestingPhases
    VERSION = 1

    PHASE_DEFINITIONS = {
      "build"               => { "label" => "Build" },
      "local_certification" => { "label" => "Local Certification" },
      "ci"                  => { "label" => "CI" },
      "review"              => { "label" => "Review" },
      "acceptance"          => { "label" => "Operator Acceptance" }
    }.freeze
    PHASE_KEYS = PHASE_DEFINITIONS.keys.freeze

    # The checkpoint NAME bin/full-suite-check bookends the local-certification phase
    # with (record_checkpoint_event name → TaskEvent#to_stage).
    CERT_CHECKPOINT = "cert"
    CERT_FINISHED = %w[completed finished failed].freeze
    # CI test-scope AgentAction slugs (config/devops_test_suites.yml ci_scopes).
    CI_SCOPES = %w[ci_test ci_lint ci_scan_ruby ci_scan_js].freeze

    module_function

    def build(task, now: Time.current)
      task = Task.includes(:task_events).find_by!(slug: task.is_a?(Task) ? task.slug : task)
      now = now.in_time_zone
      events = task.task_events.chronological.to_a
      {
        "cache_version" => VERSION,
        "cached_at" => now.iso8601,
        "phases" => {
          "build"               => build_phase(events, now: now),
          "local_certification" => certification_phase(events, now: now),
          "ci"                  => ci_phase(task, now: now),
          "review"              => review_phase(events, now: now),
          "acceptance"          => acceptance_phase(task.devops || {}, now: now)
        }
      }
    end

    # Idempotent persist — update_columns skips validations/callbacks (no re-entrancy).
    def refresh!(task, now: Time.current)
      task = Task.find_by!(slug: task) unless task.is_a?(Task)
      metrics = build(task, now: now)
      task.update_columns( # rubocop:disable Rails/SkipsModelValidations
        testing_phases: metrics,
        testing_phases_cached_at: now.in_time_zone,
        testing_phases_version: VERSION,
        updated_at: Time.current
      )
      metrics
    end

    # Serve the cached projection when it matches the current VERSION, else recompute
    # on the fly (self-healing on a version bump). Never raises into a render.
    def cached_or_built(task)
      if task.testing_phases_version == VERSION && task.testing_phases.present?
        task.testing_phases
      else
        build(task)
      end
    rescue StandardError => e
      Rails.logger.warn("[task-testing-phases] projection unavailable for #{task.slug}: #{e.class}: #{e.message}")
      empty_projection
    end

    # A safe, phases-all-missing projection — returned when a live read genuinely
    # can't build (so cached_or_built NEVER re-raises into a render, honoring its
    # contract). The card partial + aggregate already tolerate "missing" windows.
    def empty_projection
      {
        "cache_version" => VERSION,
        "cached_at" => nil,
        "phases" => PHASE_KEYS.index_with do
          { "status" => "missing", "seconds" => nil, "started_at" => nil, "completed_at" => nil, "source" => nil }
        end
      }
    end

    def refresh_recent!(limit: 100, now: Time.current)
      Task.order(updated_at: :desc).limit(limit).map { |task| [task.slug, refresh!(task, now: now)] }.to_h
    end

    # Full backfill — recompute every task's projection from its durable events.
    def backfill!(now: Time.current)
      count = 0
      Task.find_each do |task|
        refresh!(task, now: now)
        count += 1
      rescue StandardError => e
        Rails.logger.warn("[task-testing-phases] backfill skipped #{task.slug}: #{e.class}: #{e.message}")
      end
      count
    end

    # ---- per-phase derivations (each returns a span row) ----------------------

    # Build = the `building` transition → the first cert-started checkpoint (else the
    # `submitted` transition when no cert ran). Implementation + directional testing.
    def build_phase(events, now:)
      start = last_transition_to(events, "building")
      finish = first_cert(events, "started") || last_transition_to(events, "submitted")
      span(start&.occurred_at, finish&.occurred_at, now: now, source: "transition")
    end

    # Local Certification = the cert-started checkpoint → its cert-finished bookend.
    def certification_phase(events, now:)
      start = first_cert(events, "started")
      finish = last_cert_finished(events, after: start&.occurred_at)
      span(start&.occurred_at, finish&.occurred_at, now: now, source: "checkpoint")
    end

    # Review = the `submitted` transition → the `reviewed` transition.
    def review_phase(events, now:)
      start = last_transition_to(events, "submitted")
      finish = last_transition_to(events, "reviewed")
      span(start&.occurred_at, finish&.occurred_at, now: now, source: "transition")
    end

    # Operator Acceptance = approval_requested_at → approval_approved_at (devops stamps).
    def acceptance_phase(devops, now:)
      start = parse_time(devops["approval_requested_at"])
      finish = parse_time(devops["approval_approved_at"])
      span(start, finish, now: now, source: "approval")
    end

    # CI = earliest job start → latest job completion. BEST-EFFORT: the persisted
    # test-scope AgentActions keep only duration_ms + ingest occurred_at (the real CI
    # startedAt/completedAt are dropped by bin/ci-scope-capture today), so the window
    # is approximated as (occurred_at − duration) … occurred_at across the CI jobs.
    def ci_phase(task, now:)
      actions = ci_actions(task)
      return span(nil, nil, now: now, source: "ci") if actions.empty?

      finish = actions.map(&:occurred_at).max
      start = actions.map { |a| a.occurred_at - (a.duration_ms.to_i / 1000.0) }.min
      span(start, finish, now: now, source: "ci_approx")
    end

    def ci_actions(task)
      AgentAction.where(task_slug: task.slug, event_slug: CI_SCOPES).where.not(occurred_at: nil).to_a
    rescue StandardError
      []
    end

    # ---- event finders --------------------------------------------------------

    def last_transition_to(events, stage)
      events.select { |e| e.transition? && e.to_stage == stage }.last
    end

    def first_cert(events, status)
      events.find { |e| cert_checkpoint?(e) && e.metadata["status"] == status }
    end

    def last_cert_finished(events, after:)
      finished = events.select { |e| cert_checkpoint?(e) && CERT_FINISHED.include?(e.metadata["status"]) }
      finished = finished.select { |e| e.occurred_at >= after } if after
      finished.last
    end

    def cert_checkpoint?(event)
      event.checkpoint? && event.to_stage == CERT_CHECKPOINT
    end

    # ---- span construction ----------------------------------------------------

    def span(started_at, completed_at, now:, source:)
      status =
        if started_at && completed_at then "completed"
        elsif started_at then "in_progress"
        else "missing"
        end
      seconds =
        if started_at && completed_at then seconds_between(started_at, completed_at)
        elsif started_at then seconds_between(started_at, now)
        end
      {
        "status" => status,
        "seconds" => seconds,
        "started_at" => timestamp(started_at),
        "completed_at" => timestamp(completed_at),
        "source" => source
      }
    end

    def seconds_between(from, to)
      return nil unless from && to

      [(to - from).to_i, 0].max
    end

    def timestamp(value)
      value&.iso8601
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
