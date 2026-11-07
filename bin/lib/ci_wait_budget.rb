# frozen_string_literal: true

require "json"
require "time"
require_relative "ci_poll_budget"

# bin/lib/ci_wait_budget.rb — HOW LONG bin/submit's step 6 holds a PENDING PR CI, sized
# from how long that repo's PR CI has actually taken.
#
# WHAT IT FIXES (task ci-retry-killers, 2026-11-06). The wait was a flat 900 s
# (CiWait::DEFAULT_TIMEOUT_S). The refactor review measured PR CI on the hub, the
# engine and turf at a p75 above 900 s, and the engine's p50 above it, so about half of
# engine and turf submits gave up the wait before CI settled and had to be resumed by
# hand (.agents/epics/audits/refactor-review-2026-11-06/lane-devops.md, section 3).
#
# THE BUDGET. The p90 of the repo's recent PR CI settle times, plus MARGIN_S, never
# below FLOOR_S (today's 900 s) and never above the structural ceiling. A "settle
# time" is one head SHA's wall time across its workflows: they run in parallel, so the
# verdict settles when the LAST one finishes. The runs come from GitHub's own run list
# (`event=pull_request&status=success`), so a red run, which ends early, never shrinks
# the budget.
#
# THE CEILING IS RELEASE'S BUDGET, REUSED. bin/release sizes its pending-CI hold from
# the workflows' `needs:` chain of `timeout-minutes` (CiPollBudget): GitHub kills a job
# at its timeout, so no run can stay pending past that chain. That is the most the
# wait could ever need, so it bounds a measured figure that a freak run inflated.
#
# WHAT IT NEVER CHANGES. The wait still decides nothing (bin/lib/ci_wait.rb). Too few
# samples, or a read that failed, yields the floor: unknown never widens the wait,
# and never shrinks it below what it was before this file existed.
module CiWaitBudget
  FLOOR_S = 900
  # Runner queueing on a busy hour, which the history's p90 under-samples.
  MARGIN_S = 300
  # The hard cap when no workflow file can be read for the structural ceiling.
  CEILING_S = 3600
  MIN_SAMPLES = 5
  PERCENTILE = 0.9
  # One page of the newest successful PR runs. The hub runs several workflows per SHA,
  # so 100 runs is roughly 20-30 settle samples there and more on a one-workflow repo.
  RUNS_PATH = "repos/%<repo>s/actions/runs?event=pull_request&status=success&per_page=100"

  Budget = Struct.new(:timeout_s, :source, :p90_s, :samples, :ceiling_s, keyword_init: true) do
    def measured? = source == :measured
  end

  module_function

  # "owner/repo" from a PR url, or nil.
  def repo_from_pr_url(url)
    url.to_s[%r{github\.com/([^/\s]+/[^/\s]+)/pull/\d+}, 1]
  end

  def runs_path(repo) = format(RUNS_PATH, repo: repo)

  # PURE. The runs API's JSON text → one settle time (seconds) per head SHA. A run
  # without both timestamps is skipped. Unparseable text yields [].
  def settle_seconds(json_text)
    doc = JSON.parse(json_text.to_s)
    runs = doc.is_a?(Hash) ? Array(doc["workflow_runs"]) : Array(doc)
    spans = Hash.new { |h, k| h[k] = [] }
    runs.grep(Hash).each do |run|
      started = time_or_nil(run["run_started_at"])
      ended = time_or_nil(run["updated_at"])
      next unless run["head_sha"] && started && ended && ended >= started

      spans[run["head_sha"]] << [started, ended]
    end
    spans.values.map { |pairs| (pairs.map(&:last).max - pairs.map(&:first).min).round }
  rescue JSON::ParserError
    []
  end

  def time_or_nil(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # PURE. Nearest-rank percentile: the smallest sample with at least `p` of the samples
  # at or below it. nil for no samples.
  def percentile(values, p = PERCENTILE)
    sorted = Array(values).compact.sort
    return nil if sorted.empty?

    sorted[[((p * sorted.size) - 1e-9).ceil - 1, 0].max]
  end

  # PURE. The structural ceiling from a { path => workflow text } map: release's own
  # budget (CiPollBudget) over the same files, capped at CEILING_S.
  def ceiling_s(workflows)
    return CEILING_S if workflows.nil? || workflows.empty?

    CiPollBudget.budget_s(workflows, floor: FLOOR_S, ceiling: CEILING_S)
  end

  # PURE. Samples (seconds) → the Budget the wait runs under.
  def budget(samples, ceiling: CEILING_S, floor: FLOOR_S, margin: MARGIN_S, min_samples: MIN_SAMPLES)
    samples = Array(samples).compact
    top = [ceiling, floor].max
    if samples.size < min_samples
      return Budget.new(timeout_s: floor, source: :floor, p90_s: percentile(samples), samples: samples.size,
                        ceiling_s: top)
    end

    p90 = percentile(samples)
    Budget.new(timeout_s: (p90 + margin).clamp(floor, top), source: :measured, p90_s: p90,
               samples: samples.size, ceiling_s: top)
  end

  # The phrase bin/submit prints beside the timeout, so the number can be traced.
  def describe(budget)
    if budget.measured?
      "measured: p90 #{budget.p90_s}s over #{budget.samples} recent green PR run(s) + #{MARGIN_S}s margin, " \
        "floor #{FLOOR_S}s, ceiling #{budget.ceiling_s}s"
    else
      "floor: #{budget.samples} recent green PR run(s), fewer than #{MIN_SAMPLES} to measure from"
    end
  end

  # The local workflow files of a checkout, as CiPollBudget reads them.
  def local_workflows(root)
    Dir[File.join(root.to_s, ".github", "workflows", "*.y{a,}ml")].sort.to_h do |path|
      [path.delete_prefix("#{root}/"), File.read(path)]
    end
  rescue SystemCallError
    {}
  end

  # The comment bin/submit writes on the task when the wait gives up: before this, a
  # step-6 timeout left nothing on the board, because dor-check never ran.
  def timeout_note(state:, waited_s:, budget_s:, basis:, pr_url:, resume:)
    "SUBMIT CI WAIT TIMED OUT: CI was still #{state} on #{pr_url} after #{waited_s.round}s " \
      "(budget #{budget_s}s, #{basis}). Nothing was refused; the task stays in building. " \
      "Resume once CI settles: #{resume}"
  end
end
