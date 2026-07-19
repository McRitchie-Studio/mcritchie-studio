# frozen_string_literal: true

require "json"
require_relative "full_suite_gate"

# FastLane — the pure decisions behind the two fast-lane ORCHESTRATION wrappers,
# `bin/task begin` (create → worktree → bind → claim → preflight) and `bin/ship`
# (commit → cert → push → PR → record → submit).
#
# The wrappers collapse the standing DevOps cycle into one command each WITHOUT
# changing any gate semantics: every gate still runs (bin/fast-check,
# bin/dor-check, the claim gate, the read-back verify), the wrappers only
# sequence them and skip a step whose OUTCOME is already durably recorded — that
# is what makes a rerun after a partial failure CONTINUE instead of duplicate.
# The skip decisions live here, pure and unit-tested; the I/O stays in the
# scripts.
module FastLane
  module_function

  # The slug `bin/task create` would derive from this title — a local mirror of
  # Task#generate_slug's `title.parameterize` (ASCII form; titles are 3-5 plain
  # words by the create API's own naming discipline). `begin` passes it as an
  # EXPLICIT --slug so the resume key is deterministic: rerunning the same
  # `begin` finds the task it created instead of minting an auto-suffixed twin.
  def derive_slug(title)
    title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  # The already-open PR for the branch, from `gh pr list --json
  # number,url,isDraft,baseRefName` output — or nil (no PR yet / unparseable).
  # Ship's PR step is idempotent BECAUSE it asks this first: an existing open PR
  # is repaired in place (`gh pr ready`, `gh pr edit --base`) rather than
  # duplicated.
  def open_pr(json_text)
    parsed = JSON.parse(json_text.to_s)
    parsed.is_a?(Array) ? parsed.first : nil
  rescue JSON::ParserError
    nil
  end

  # The PR body — the task URL is the FIRST line (the review supervisor and the
  # qa-release sweep key on it), then the acceptance bullets so the reviewer
  # reads the contract without a board round-trip.
  def pr_body(task_url, acceptance = [])
    lines = [task_url.to_s]
    bullets = Array(acceptance).map { |item| item.to_s.strip }.reject(&:empty?)
    unless bullets.empty?
      lines << ""
      lines << "Acceptance:"
      bullets.each { |item| lines << "- #{item}" }
    end
    "#{lines.join("\n")}\n"
  end

  # Is the task already certified for EXACTLY this working tree? True when the
  # recorded checks_run carries a FRESH fast-cert — or a fresh FULL cert (both
  # full lanes) — bound to `fingerprint`. Ship skips its bin/fast-check step on
  # true: the gate's outcome for this tree is already durably recorded, so a
  # rerun resumes instead of re-paying the cert. ANY edit changes the tree hash
  # and re-arms the step — this can never skip a cert the code hasn't earned.
  def cert_fresh?(checks_run, fingerprint)
    checks = Array(checks_run)
    return false if fingerprint.to_s.strip.empty?
    return true if FullSuiteGate.lane_status(checks, FullSuiteGate::FAST_LANE, fingerprint) == :fresh

    FullSuiteGate::LANES.all? { |lane| FullSuiteGate.lane_status(checks, lane, fingerprint) == :fresh }
  end
end
