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
  # PR #1334 corrected that sentence in the entry docs (docs/agents/claude.md and
  # index.md) and pinned it with test/docs/fast_lane_hub_path_docs_test.rb; this is the
  # half the TOOL speaks — and the tool wins any disagreement, because it speaks last
  # and at the moment of action.
  #
  # THE PATH IS ONLY HALF THE INSTRUCTION. The path picks the SCRIPT; the cwd picks
  # the TREE it acts on — and ship does NOT refuse a foreign root. It roots at the cwd's
  # git toplevel, then RE-ROOTS at the task's desk and says so ("re-rooting at the task
  # worktree … (you ran from …)", bin/ship's `--- rooting ---` block), running every gate
  # chdir'd to the resolved desk; it dies ONLY when no desk resolves on disk. So the cwd
  # is still half the instruction, for two reasons that are not a refusal by ship: (1) a
  # re-root is a correction the reader has to notice and trust, not the tree they chose;
  # (2) the cert WRITERS the builder runs by hand afterwards refuse ANY foreign root
  # outright — "this run roots at …/mcritchie-studio (branch main), which is not <slug>'s
  # tree — refusing to certify it". That string is CertRootGuard#refusal_message, and ship
  # dies with the SAME string when no desk resolves (bin/ship: `die!(assessment[:message])
  # unless resolved`); what ship never does is refuse a root it CAN re-root from. A hint
  # that fixes only the path leaves the builder one by-hand cert from that refusal.
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

  # ── remedy hints ─────────────────────────────────────────────────────────────
  #
  # A REMEDY IS AN INSTRUCTION, AND AN INSTRUCTION MUST RESOLVE. When a fast-lane
  # script refuses, it hands the reader a command to run — "Re-run bin/fast-check
  # <slug>", "re-run bin/ship <slug>". Every one of those scripts (ship, fast-check,
  # full-suite-check, dor-check, task) lives in mcritchie-studio/bin ALONE, so the
  # bare form resolves only from a hub desk. A builder standing on a turf-monster,
  # rolio, or gem desk — who reached the script through its ABSOLUTE path, because
  # that is the only way they could have reached it — follows the tool's own hint
  # and gets `No such file or directory`. PR #1334 corrected the sentence in the
  # entry docs and PR #1341 corrected `bin/task begin`'s handoff line; this is the
  # same defect wherever a script tells the reader to run something.
  #
  # PROSE IS NOT AN INSTRUCTION, and this deliberately leaves prose alone. A message
  # that NAMES a script as a subject — "could not be read (bin/task show)",
  # "bin/dor-check credits this receipt only alongside a green CI", "another
  # bin/release is deploying from that checkout" — is describing a thing, not
  # handing over a command. Absolutising those would make every refusal longer and
  # harder to read while fixing nothing, because nobody pastes them. The tell is an
  # OPERAND: an instruction carries the slug (or the flags) the reader is meant to
  # paste. test/lib/remedy_hint_guard_test.rb pins that distinction so a new bare
  # instruction fails instead of shipping.
  #
  # ── WHICH COPY, AND WHY `bin_dirs` IS ORDERED ────────────────────────────────
  #
  # Resolution is against the FILESYSTEM — the first `bin_dirs` entry that actually
  # carries an executable by that name — never against a repo's identity. Resolving
  # by existence self-heals: onboard a repo, or give a satellite a shim, and the
  # hint follows the disk instead of a registry somebody has to remember to update.
  # If NO candidate exists, the LAST directory is used, so the reader still gets an
  # absolute path they can reason about instead of a bare word that hides the
  # question.
  #
  # THE TWO CALLERS PASS DIFFERENT ORDERS, and the difference is the whole design:
  #
  #   A RE-RUN remedy names a script for the tree the speaker is ALREADY IN, so it
  #   passes ONE directory — the speaking script's own `__dir__`. That is stronger
  #   than any search: it names the very script that is talking, and its siblings
  #   beside it. A builder who invoked the hub's fast-check from a satellite desk is
  #   told to re-run THAT fast-check; a hub builder who invoked their own desk's is
  #   told to re-run THEIRS. Neither can be mis-pointed, because neither is guessed.
  #
  #   A HANDOFF remedy names a script for a DIFFERENT tree (`bin/task begin` runs at
  #   the hub and points at the desk it just made), so it passes the desk's bin dir
  #   FIRST and the hub's second — desk-first, hub-fallback. Desk-first is not
  #   cosmetic there: bin/ship resolves its GATES from its own __dir__ (TASK_BIN /
  #   FAST_CHECK_BIN / DOR_CHECK_BIN, bin/ship:100-102), so always-hub would silently
  #   re-point every HUB task's gate lane at the primary checkout, which routinely
  #   lags `accepted`. That is a gate-selection change wearing a hint fix's clothes.
  #
  # ── WHY A RE-RUN REMEDY CARRIES NO `cd` ──────────────────────────────────────
  #
  # The path picks the SCRIPT; the cwd picks the TREE it acts on, and CertRootGuard
  # refuses a cert rooted anywhere but the task's desk — so a handoff that fixes only
  # the path fails in the mirror direction, which is why FastLane.handoff_command
  # leads with `cd <desk> &&`. A re-run remedy is the opposite case: the reader is
  # standing in the tree already (they just ran the script from it, and for the cert
  # writers the root guard proved it), so a `cd` would restate where they are. The
  # one seam that speaks BEFORE rooting — bin/ship's claim refusal — is safe for the
  # same reason from the other side: ship RE-ROOTS to the task's desk rather than
  # refusing, and says so.
  def resolve_bin(script, *bin_dirs)
    dirs = bin_dirs.flatten.compact.map(&:to_s).reject { |dir| dir.strip.empty? }
    return script.to_s if dirs.empty?

    candidates = dirs.map { |dir| File.expand_path(script.to_s, dir) }
    candidates.find { |path| File.executable?(path) } || candidates.last
  end

  # The remedy line itself: an absolute, resolvable script followed by the operands
  # the reader pastes. `bin_dirs` may be one directory (a re-run) or an ordered
  # preference list (a handoff); see resolve_bin. Blank args are dropped so a caller
  # can pass a conditional flag without minting a double space in a pasted command.
  def remedy_command(script, bin_dirs, *args)
    parts = [resolve_bin(script, bin_dirs)]
    parts.concat(args.flatten.map(&:to_s).reject { |arg| arg.strip.empty? })
    parts.join(" ")
  end
end
