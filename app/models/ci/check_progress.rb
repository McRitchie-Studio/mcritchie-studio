# frozen_string_literal: true

module Ci
  # A commit's GitHub CI progress reduced to the ONE fact a progress bar needs:
  # how many checks have PASSED out of the TOTAL, plus a coarse state for colour.
  # This is the reusable info-viz datum behind `components/_ci_progress_bar` — a
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

    # Under this many checks the "X / Y" fraction + bar gives way to ONE SYMBOL PER
    # CHECK (v1.2 of visual-ci-progress-bars): a handful of jobs reads clearer as
    # ✅/❌/🔄 mapped 1:1 to the real CI jobs than as a fraction. At or above it the
    # individual glyphs would crowd, so the numeric bar stays. `< 12` = symbols.
    SYMBOLIC_THRESHOLD = 12

    # One folded check: its coarse state (:passed / :failed / :pending) and its
    # GitHub job NAME (for the symbol's hover title — nil from the count-only
    # fixture seam, which has no per-check identity). The unit the symbolic row
    # draws one glyph per; the counts are just a tally of these.
    Check = Struct.new(:state, :name) do
      def passed?  = state == :passed
      def failed?  = state == :failed
      def pending? = state == :pending
    end

    attr_reader :passed, :failed, :pending, :total, :sha, :checks

    # The always-safe "nothing to show" datum — no PR yet, no CI run, an
    # unreadable/absent payload. `present?` is false, so the bar renders nothing.
    def self.blank(sha: nil)
      new(passed: 0, failed: 0, pending: 0, sha: sha)
    end

    # PURE. A check-runs array (each `{ "status" =>, "conclusion" =>, "name" => }`)
    # -> a per-check datum. Accepts the raw GitHub run objects; unknown/blank rows
    # fold to `pending` rather than being dropped, so `total` always equals the rows
    # seen. Each run's `name` rides along so the symbolic row can title its glyph.
    def self.from_check_runs(runs, sha: nil)
      checks = Array(runs).map { |run| Check.new(bucket_for(run), run_name(run)) }
      new(checks: checks, sha: sha)
    end

    # PURE. One run's status+conclusion -> :passed / :failed / :pending.
    def self.bucket_for(run)
      run = run || {}
      status = run["status"].to_s.downcase
      return :pending unless status == "completed"

      CHECK_RUN_BUCKETS.fetch(run["conclusion"].to_s.downcase, :pending)
    end

    # PURE. One run's job name, or nil — the symbolic row titles each glyph with it.
    def self.run_name(run)
      (run || {})["name"].to_s.presence
    end

    # Two shapes fold in: a per-check list (`checks:`) from the check-runs / live
    # CiCheckJob path, which carries each job's real state + name; or bare
    # passed/failed/pending counts from the count-only fixture seam, which
    # synthesize nameless checks so a symbolic row still renders the right glyph
    # mix. The checks list is the single source of truth — counts derive FROM it.
    def initialize(passed: 0, failed: 0, pending: 0, sha: nil, checks: nil)
      @checks  = checks ? checks.map { |check| coerce_check(check) } : synthesize_checks(passed, failed, pending)
      @passed  = @checks.count(&:passed?)
      @failed  = @checks.count(&:failed?)
      @pending = @checks.count(&:pending?)
      @total   = @checks.size
      @sha     = sha.presence
    end

    # Something worth drawing a bar for — at least one check exists. A zero-check
    # commit (never built, unreadable) stays invisible.
    def present?
      total.positive?
    end

    def blank?
      !present?
    end

    # A few checks render as one symbol each; a crowd keeps the numeric bar. Both
    # require at least one check — a blank datum draws nothing in either mode.
    def symbolic?
      present? && total < SYMBOLIC_THRESHOLD
    end

    def numeric?
      present? && !symbolic?
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

    # "5 / 8" — the X of Y the operator asked for.
    def fraction_label
      "#{passed} / #{total}"
    end

    def to_h
      { passed: passed, failed: failed, pending: pending, total: total, state: state, sha: sha }
    end

    private

    # Accept an already-built Check, or a bare state symbol/string (which the
    # synthesized fixture path never hits, but keeps the constructor forgiving).
    def coerce_check(check)
      return check if check.is_a?(Check)

      Check.new(check.to_sym, nil)
    end

    # Count-only input (the fixture seam) -> nameless per-check data in a stable
    # passed → failed → pending order, so the symbolic row still groups its glyphs.
    def synthesize_checks(passed, failed, pending)
      { passed: passed, failed: failed, pending: pending }.flat_map do |state, count|
        Array.new(count.to_i) { Check.new(state, nil) }
      end
    end
  end
end
