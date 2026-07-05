# frozen_string_literal: true

require "json"
require "shellwords"

# The REAL GitHub CI state of a PR, reduced to one verdict so bin/dor-check's merge
# gate can refuse to hand a red PR to review — the #1 blocker class (a PR green
# LOCALLY but red on CI, because bin/full-suite-check certifies `bin/rails test` and
# NOT the browser `test:system` lane GitHub also runs). Reads
# `gh pr checks <pr> --json name,state,bucket` and folds gh's normalized `bucket`
# (pass/fail/pending/skipping/cancel) into one state:
#   :red        — a check failed/cancelled            → BLOCK the gate
#   :pending    — a check still running, none failed   → BLOCK (not green YET)
#   :green      — every check passed/skipped           → pass
#   :none       — the PR has no checks reported yet     → note (non-blocking)
#   :no_pr      — no pr_url yet                         → note (gate re-runs after push)
#   :unverified — gh/network error                      → note (never a hard block;
#                 don't trade a flaky CI lane for a flaky gate)
#
# `injected` is dor-check's DOR_CHECK_CI_STATUS seam: a bare token
# (green/red/pending/none/unverified/no_pr) OR the raw `gh pr checks --json` array —
# so the tests never shell out to gh (mirrors DOR_CHECK_SUITE_EVIDENCE).
module CiStatus
  TOKENS = %w[green red pending none unverified no_pr].freeze

  def self.evaluate(pr_url, injected = nil)
    pr = pr_url.to_s.strip
    raw = injected.to_s.strip
    return { state: raw.to_sym, failing: ["ci"], pending: ["ci"] } if TOKENS.include?(raw)

    if raw.empty?
      return { state: :no_pr } if pr.empty?

      raw = `gh pr checks #{Shellwords.escape(pr)} --json name,state,bucket 2>&1`.to_s.strip
    end
    parse(raw)
  end

  # gh's --json array → verdict. A non-array (an error message like "no checks
  # reported on the 'X' branch", or a `gh: command not found`) can't be a red gate,
  # so it degrades to :none / :unverified rather than blocking.
  def self.parse(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    unless data.is_a?(Array)
      return { state: :none } if raw.to_s =~ /no checks|no commit statuses/i

      return { state: :unverified, reason: raw.to_s.lines.first.to_s.strip[0, 140] }
    end
    return { state: :none } if data.empty?

    name = ->(c) { c["name"].to_s.empty? ? c["state"].to_s : c["name"].to_s }
    failing = data.select { |c| %w[fail cancel].include?(c["bucket"].to_s) }.map(&name)
    pending = data.select { |c| c["bucket"].to_s == "pending" }.map(&name)
    return { state: :red, failing: failing } if failing.any?
    return { state: :pending, pending: pending } if pending.any?

    { state: :green, count: data.size }
  end
end
