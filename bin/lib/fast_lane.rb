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

  # THE HANDOFF LINE `bin/task begin` PRINTS LAST — the final instruction a builder
  # reads before working, and until 2026-09-09 the wrong one. It printed `bin/ship
  # <slug>`, the BARE form, which resolves ONLY from a hub desk: every fast-lane
  # script (ship, fast-check, full-suite-check, dor-check, task) lives in
  # mcritchie-studio/bin alone, so a builder on a turf-monster or rolio desk who
  # followed the tool's own hint got `nohup: bin/ship: No such file or directory`.
  # PR #1334 corrected that sentence in the generated entry docs; this is the half
  # the TOOL speaks — and the tool wins any disagreement, because it speaks last and
  # at the moment of action.
  #
  # THE PATH IS ONLY HALF THE INSTRUCTION. The path picks the SCRIPT; the cwd picks
  # the TREE it acts on. bin/ship roots at the cwd's git toplevel and CertRootGuard
  # REFUSES when that is not the task's tree (measured: "this run roots at
  # …/mcritchie-studio (branch main), which is not <slug>'s tree — refusing to
  # certify it"), so a hint that fixes only the path fails in the OPPOSITE direction.
  # This line names BOTH and is copy-pasteable verbatim: `cd <desk> && <ship> <slug>`.
  #
  # WHY THE FORM IS UNCONDITIONALLY ABSOLUTE — never a bare `bin/ship`, not even for
  # a hub desk. A bare form is correct only when the reader's cwd happens to carry the
  # script, so it encodes an assumption about the reader that the printer cannot
  # check. An absolute path is longer and cannot be wrong; and ONE arm means the arm
  # the guard exercises is the arm every builder is handed.
  #
  # WHICH ship is resolved against the FILESYSTEM, not against the repo's identity:
  # the desk's own bin/ship when the desk carries an executable one (every hub desk
  # does), else the hub's — the script beside the bin/task that is speaking. Two
  # reasons for desk-first over always-hub. (1) It leaves the hub lane byte-identical
  # to the bare form it replaces, so the busiest desk in the house changes nothing but
  # the printed path. (2) bin/ship resolves its GATES from its own __dir__
  # (bin/fast-check, bin/dor-check, bin/task) and a primary routinely lags `accepted`,
  # so pointing a fresh desk at a stale primary's gates would be a real regression
  # bought for nothing. A satellite desk carries no bin/ship and falls through to the
  # hub, which is exactly what the docs now prescribe. Resolving by EXISTENCE rather
  # than by repo slug also self-heals: onboard a repo, or give a satellite a shim, and
  # the hint follows the disk instead of a registry that has to be remembered.
  def handoff_command(slug, worktree_dir, hub_bin_dir)
    desk_ship = File.join(worktree_dir.to_s, "bin", "ship")
    ship = File.executable?(desk_ship) ? desk_ship : File.expand_path("ship", hub_bin_dir.to_s)
    "cd #{worktree_dir} && #{ship} #{slug}"
  end

  # Did a `git push` fail specifically because the branch is NON-FAST-FORWARD —
  # the shape a REBASED branch produces (routine here: accepted moves and desks
  # rebase onto it)? True ⇒ ship retries with --force-with-lease (safe: the lease
  # refuses if the remote moved under us). False on any OTHER failure (auth,
  # network, a protected ref) — those are not a rebase and must never be forced.
  # Reads git's own rejection wording; nil/blank ⇒ false.
  def push_rejected_non_fast_forward?(push_output)
    text = push_output.to_s
    text.match?(/\((?:non-fast-forward|fetch first)\)/) || text.match?(/!\s*\[rejected\]/)
  end
end
