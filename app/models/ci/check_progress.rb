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

    attr_reader :passed, :failed, :pending, :total, :sha

    # The always-safe "nothing to show" datum — no PR yet, no CI run, an
    # unreadable/absent payload. `present?` is false, so the bar renders nothing.
    def self.blank(sha: nil)
      new(passed: 0, failed: 0, pending: 0, sha: sha)
    end

    # PURE. A check-runs array (each `{ "status" =>, "conclusion" => }`) -> counts.
    # Accepts the raw GitHub run objects; unknown/blank rows fold to `pending`
    # rather than being dropped, so `total` always equals the rows seen.
    def self.from_check_runs(runs, sha: nil)
      runs = Array(runs)
      tally = Hash.new(0)
      runs.each { |run| tally[bucket_for(run)] += 1 }
      new(passed: tally[:passed], failed: tally[:failed], pending: tally[:pending], sha: sha)
    end

    # PURE. One run's status+conclusion -> :passed / :failed / :pending.
    def self.bucket_for(run)
      run = run || {}
      status = run["status"].to_s.downcase
      return :pending unless status == "completed"

      CHECK_RUN_BUCKETS.fetch(run["conclusion"].to_s.downcase, :pending)
    end

    def initialize(passed:, failed:, pending:, sha: nil)
      @passed = passed.to_i
      @failed = failed.to_i
      @pending = pending.to_i
      @total = @passed + @failed + @pending
      @sha = sha.presence
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

    # "5 / 8" — the X of Y the operator asked for.
    def fraction_label
      "#{passed} / #{total}"
    end

    def to_h
      { passed: passed, failed: failed, pending: pending, total: total, state: state, sha: sha }
    end
  end
end
