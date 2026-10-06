# frozen_string_literal: true

require "yaml"

# bin/lib/ci_poll_budget.rb — HOW LONG a release gate may hold on a PENDING CI verdict,
# sized from the workflows that produce that verdict rather than guessed.
#
# WHAT IT FIXES (task gem-gate-outwaits-consumer-ci). The gem publish gate and the
# pre-QA gate polled a flat RELEASE_CI_POLL_TIMEOUT (1200 s). studio-engine's verdict
# includes Consumer CI (refs -> four hub shards + turf + industries -> aggregate) and
# Engine CI's browser lane, and on a fresh release tip that takes longer than 20
# minutes. Every release sweep on 2026-10-05/06 aborted at the gem preflight with
# "GitHub CI is pending" and needed a manual re-run once CI went green. Fail-closed was
# correct; the window was simply shorter than the thing it waited on.
#
# THE BUDGET, BY CONSTRUCTION. GitHub kills a job at its `timeout-minutes`, so a
# workflow cannot stay pending past the longest `needs:` chain of those timeouts (plus
# queue time). Workflows on one SHA run in parallel, so the verdict settles within the
# LONGEST workflow's chain, counting only the workflows that run on push or pull_request
# (gating?). The budget is that chain plus HEADROOM_S for runner queueing,
# never below the operator's floor (RELEASE_CI_POLL_TIMEOUT) and never above a hard
# ceiling (RELEASE_CI_POLL_CEILING).
#
# WHAT IT NEVER CHANGES. This sizes only how long a :wait verdict is HELD. A red or
# unreadable verdict still aborts on the first read (ci_poll_action owns that split),
# and a verdict still pending at the deadline still fails closed. A workflow set that
# cannot be read yields nil, and the caller keeps the floor: unknown never widens.
module CiPollBudget
  # GitHub's own default when a job declares no timeout-minutes.
  GITHUB_DEFAULT_JOB_MINUTES = 360
  # Runner queueing and job start-up, which timeout-minutes does not count.
  HEADROOM_S = 600

  module_function

  # The longest `needs:` chain of job timeouts in ONE workflow, in minutes. nil when the
  # text is not a workflow (unparseable, or no jobs). A job with no timeout (or an
  # expression GitHub resolves at run time) counts as GitHub's 360-minute default, and
  # the ceiling then bounds it. A `needs:` cycle or unknown name is ignored rather than
  # trusted: GitHub would refuse such a workflow outright.
  def critical_path_minutes(yaml_text)
    doc = YAML.safe_load(yaml_text.to_s, aliases: true)
    jobs = doc.is_a?(Hash) ? doc["jobs"] : nil
    return nil unless jobs.is_a?(Hash) && jobs.any?

    memo = {}
    longest = lambda do |name, seen|
      return memo[name] if memo.key?(name)
      return 0 if seen.include?(name) || !jobs[name].is_a?(Hash)

      job = jobs[name]
      before = Array(job["needs"]).map(&:to_s).map { |dep| longest.call(dep, seen + [name]) }.max || 0
      memo[name] = before + job_minutes(job)
    end
    jobs.keys.map { |name| longest.call(name.to_s, []) }.max
  rescue StandardError
    nil
  end

  def job_minutes(job)
    raw = job["timeout-minutes"]
    raw.is_a?(Numeric) && raw.positive? ? raw.ceil : GITHUB_DEFAULT_JOB_MINUTES
  end

  # The events whose runs produce the verdict a release gate reads. A schedule-,
  # workflow_dispatch- or workflow_run-only workflow (r2-backup, devnet-nightly,
  # engine-lock-automerge) never runs on the SHA under test, so its chain must not size
  # the wait (task ci-poll-refreshes-its-token). Measured 2026-10-06, none of them yet
  # outlasts its repo's ci.yml, so this is the guard against the day one does: a slow
  # nightly would otherwise hold every gate for a run that never comes.
  GATING_EVENTS = %w[push pull_request].freeze

  # TRUE when the workflow triggers on push or pull_request. Reads `on:` in all three
  # spellings GitHub accepts (a string, a list, a map of event => filters) and under
  # BOTH keys Psych may give it: YAML 1.1 reads a bare `on` as the boolean true.
  # Unparseable or trigger-less text is not gating: GitHub would not run it.
  def gating?(yaml_text)
    doc = YAML.safe_load(yaml_text.to_s, aliases: true)
    return false unless doc.is_a?(Hash)

    on = doc.key?("on") ? doc["on"] : doc[true]
    events = on.is_a?(Hash) ? on.keys : Array(on)
    events.map(&:to_s).intersect?(GATING_EVENTS)
  rescue StandardError
    false
  end

  # Seconds to hold a pending verdict, given every workflow text on the SHA. Only the
  # gating workflows count. Returns the floor when none yields a chain, so an unreadable
  # set never widens the wait.
  def budget_s(workflow_texts, floor:, ceiling:)
    chains = Array(workflow_texts).select { |text| gating?(text) }.filter_map { |text| critical_path_minutes(text) }
    return floor if chains.empty?

    sized = (chains.max * 60) + HEADROOM_S
    [[sized, floor].max, [ceiling, floor].max].min
  end
end
