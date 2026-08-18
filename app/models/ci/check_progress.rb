# frozen_string_literal: true

module Ci
  # A commit's GitHub CI progress reduced to the ONE fact a progress bar needs:
  # how many checks have PASSED out of the TOTAL, plus a coarse state for colour.
  # This is the reusable info-viz datum behind `components/_ci_progress_meter` — a
  # plain value object, no persistence, folded from a check-runs payload by
  # `Ci::ProgressReader`.
  #
  # WHY A SECOND FOLD (vs. bin/lib/ci_status.rb's `for_sha`): that CLI library
  # answers the release gate's yes/no question and returns an overall verdict —
  # `count` only on green, name-arrays on red/pending — never passed AND total
  # together. A meter needs both numbers at every state, so the bucket mapping is
  # mirrored here (kept byte-for-byte in step with CHECK_RUN_BUCKETS) and re-folded
  # into counts. One vocabulary, two shapes, on purpose.
  class CheckProgress
    # GitHub `conclusion` -> our coarse bucket. Mirrors bin/lib/ci_status.rb's
    # CHECK_RUN_BUCKETS (success/neutral/skipped are "done, not a failure";
    # failure/timed_out/action_required/startup_failure/stale/cancelled are bad).
    # Anything not yet `completed`, and any conclusion GitHub adds later that we
    # do not know, is `pending` — a run still in flight is never a pass or a fail.
    CHECK_RUN_BUCKETS = {
      "success" => :passed,
      "neutral" => :passed,
      "skipped" => :passed,
      "cancelled" => :failed,
      "failure" => :failed,
      "timed_out" => :failed,
      "action_required" => :failed,
      "startup_failure" => :failed,
      "stale" => :failed
    }.freeze

    # One folded check: its coarse state (:passed / :failed / :pending) and its
    # GitHub job NAME (for the symbol's hover title — nil from the count-only
    # fixture seam, which has no per-check identity). The unit the symbolic row
    # draws one glyph per; the counts are just a tally of these.
    Check = Struct.new(:state, :name, :started_at, :completed_at) do
      def passed?  = state == :passed
      def failed?  = state == :failed
      def pending? = state == :pending
    end

    # Draw order for the marks inside the meter rail: FAILURES left, still-running in
    # the middle, passes right — so a check migrates left when it goes red and right
    # when it goes green, and the marks a width cap has to drop are the least
    # informative ones (surplus passes), never a failure. Mirrors
    # ApplicationHelper::RELEASE_METER_MARK_RANK, which draws the release lanes the
    # same way; ties break on the check NAME so the row is stable across re-renders
    # (the source rows come back in Postgres heap order and reshuffle as they update).
    MARK_RANK = { failed: 0, pending: 1, passed: 2 }.freeze

    attr_reader :passed, :failed, :pending, :total, :sha, :checks, :run_started_at

    # The always-safe "nothing to show" datum — no PR yet, no CI run, an
    # unreadable/absent payload. `present?` is false, so the bar renders nothing.
    def self.blank(sha: nil)
      new(passed: 0, failed: 0, pending: 0, sha: sha)
    end

    # PURE. A check-runs array (each `{ "status" =>, "conclusion" =>, "name" => }`)
    # -> a per-check datum. Accepts the raw GitHub run objects; unknown/blank rows
    # fold to `pending` rather than being dropped, so `total` always equals the rows
    # seen. Each run's `name` rides along so the symbolic row can title its glyph.
    def self.from_check_runs(runs, sha: nil, run_started_at: nil)
      checks = Array(runs).map do |run|
        Check.new(bucket_for(run), run_name(run), run_time(run, "started_at"), run_time(run, "completed_at"))
      end
      new(checks: checks, sha: sha, run_started_at: run_started_at)
    end

    # PURE. One run's status+conclusion -> :passed / :failed / :pending.
    def self.bucket_for(run)
      run = run || {}
      status = run["status"].to_s.downcase
      return :pending unless status == "completed"

      CHECK_RUN_BUCKETS.fetch(run["conclusion"].to_s.downcase, :pending)
    end

    # PURE. One run's job name, or nil — the meter titles each mark with it.
    def self.run_name(run)
      (run || {})["name"].to_s.presence
    end

    # PURE. One timestamp off a check row, as a Time or nil. Two shapes reach here: a
    # Time from the ci_check_jobs pluck (the live path) and an ISO-8601 STRING from
    # the GitHub check-runs API (the fallback). An unparseable value is nil — a
    # missing clock hides the meter's timer, it never raises into the render.
    def self.run_time(run, key)
      value = (run || {})[key]
      return value if value.is_a?(Time)
      return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)

      Time.zone.parse(value.to_s).presence
    rescue ArgumentError, TypeError
      nil
    end

    # Two shapes fold in: a per-check list (`checks:`) from the check-runs / live
    # CiCheckJob path, which carries each job's real state + name; or bare
    # passed/failed/pending counts from the count-only fixture seam, which
    # synthesize nameless checks so a symbolic row still renders the right glyph
    # mix. The checks list is the single source of truth — counts derive FROM it.
    def initialize(passed: 0, failed: 0, pending: 0, sha: nil, checks: nil, run_started_at: nil)
      @checks  = checks ? checks.map { |check| coerce_check(check) } : synthesize_checks(passed, failed, pending)
      @passed  = @checks.count(&:passed?)
      @failed  = @checks.count(&:failed?)
      @pending = @checks.count(&:pending?)
      @total   = @checks.size
      @sha     = sha.presence
      # The RUN's own start (github_workflow_runs.run_started_at) outranks the checks'
      # — a job that queued late still belongs to a run that began earlier.
      @run_started_at = run_started_at
    end

    # Something worth drawing a bar for — at least one check exists. A zero-check
    # commit (never built, unreadable) stays invisible.
    def present?
      total.positive?
    end

    def blank?
      !present?
    end

    # Coarse state, colour-only. A failure OUTRANKS an in-flight check (a known-bad
    # run is never "still going"); an all-done run with no failures is green.
    def state
      return :none if total.zero?
      return :red if failed.positive?
      return :pending if pending.positive?

      :green
    end

    def green? = state == :green
    def red? = state == :red
    def pending? = state == :pending

    # Bar fill 0.0..1.0 — passed over total. Zero when there is nothing to divide.
    def ratio
      return 0.0 if total.zero?

      passed.fdiv(total)
    end

    # Whole-number percent for the bar width + aria-valuenow.
    def percent
      (ratio * 100).round
    end

    # Checks that have SETTLED either way, and that share of the suite. This is what
    # the card meter's fill measures: a run with a failure still fills its bar as it
    # finishes, and the bar's COLOUR (state) is what says the run went bad. Measuring
    # passes alone left a red suite's bar visually stuck — 1 failed of 10 read as "9%
    # done" while CI was in fact nearly finished.
    def resolved
      passed + failed
    end

    def resolved_percent
      return 0 if total.zero?

      (resolved.fdiv(total) * 100).round
    end

    # "5 / 8" — the X of Y the operator asked for.
    def fraction_label
      "#{passed} / #{total}"
    end

    # The checks in MARK_RANK order — what the meter rail draws left to right.
    def ordered_checks
      checks.sort_by { |check| [MARK_RANK.fetch(check.state, 1), check.name.to_s] }
    end

    # When this CI run BEGAN: the run's own stamp when we have it, else the earliest
    # check to start, else nil (no clock — the meter simply shows no timer).
    def started_at
      run_started_at || checks.filter_map(&:started_at).min
    end

    # When it FINISHED, or nil while anything is still running. A run is only over
    # when every check has settled, so a half-done suite reports no finish — that is
    # what makes the meter's clock tick live and then freeze exactly once.
    def finished_at
      return nil if pending.positive? || total.zero?

      checks.filter_map(&:completed_at).max
    end

    # Still moving? (at least one check unsettled). The meter ticks a LIVE clock in
    # this state and shows the frozen duration otherwise.
    def running?
      pending.positive?
    end

    # Whole seconds the run TOOK, or nil while it is still running / has no clock.
    # This is what the card shows once CI settles: not "how long ago" but "how long
    # it took", which stops moving and stays true.
    def duration_seconds
      from = started_at
      to = finished_at
      return nil unless from && to

      [(to - from).to_i, 0].max
    end

    def to_h
      { passed: passed, failed: failed, pending: pending, total: total, state: state, sha: sha }
    end

    private

    # Accept an already-built Check, or a bare state symbol/string (which the
    # synthesized fixture path never hits, but keeps the constructor forgiving).
    def coerce_check(check)
      return check if check.is_a?(Check)

      Check.new(check.to_sym, nil, nil, nil)
    end

    # Count-only input (the fixture seam) -> nameless per-check data in a stable
    # passed → failed → pending order, so the symbolic row still groups its glyphs.
    def synthesize_checks(passed, failed, pending)
      { passed: passed, failed: failed, pending: pending }.flat_map do |state, count|
        Array.new(count.to_i) { Check.new(state, nil, nil, nil) }
      end
    end
  end
end
