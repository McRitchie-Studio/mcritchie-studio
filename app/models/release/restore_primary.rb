class Release
  # Pure decision logic for restoring a PRIMARY checkout to a clean canonical
  # branch — the COMPLEMENT of Release::ShipSequence.preflight_offenders.
  #
  # preflight_offenders DETECTS a primary that drifted off a clean `main` during a
  # review/QA cycle (a leftover `pr-NNN` branch, a stale uncommitted schema.rb).
  # This decides how to FIX one. The two AGREE on what "clean main" means: the
  # restore target is CANONICAL_BRANCH == ShipSequence's `on_main` branch ("main"),
  # and a dirty tree blocks a restore exactly as it makes a checkout an offender.
  #
  # Like ShipSequence this is deliberately IO-free: no git, no fetch, no checkout.
  # It takes a gathered git state in and returns a plan (symbols/strings/arrays)
  # out, so the git reads/writes stay in the bin script and ALL the safety logic
  # stays here, unit tested.
  #
  # The cardinal rule: NEVER discard work. A checkout with uncommitted changes OR
  # commits not on any remote ("unpushed") is REFUSED — the operator resolves it by
  # hand. Only a checkout that is provably safe (clean tree + every commit pushed)
  # is restored: checkout `main`, fast-forward to origin.
  module RestorePrimary
    module_function

    # The branch a primary checkout is restored to. MUST equal ShipSequence's
    # `on_main` literal so detect (preflight_offenders) and fix (this) agree on
    # what "clean main" means.
    CANONICAL_BRANCH = "main"

    # The restore plan for a single checkout. `state` is a string/sym-keyed hash:
    #   { "branch"      => <current branch (`git rev-parse --abbrev-ref HEAD`)>,
    #     "dirty_files" => [paths from `git status --porcelain`],
    #     "unpushed"    => [commits on HEAD not on any remote
    #                       (`git log HEAD --not --remotes`)] }
    # `dirty_files` and `unpushed` each default to empty when absent.
    #
    # Returns a string-keyed plan:
    #   { "action" => "refuse",  "branch" =>, "reasons" => [..],
    #     "dirty_files" => [..], "unpushed" => [..] }
    #   { "action" => "restore", "branch" => CANONICAL_BRANCH,
    #     "from_branch" =>, "already_on_canonical" => <bool> }
    #
    # `restore` ALWAYS fast-forwards to origin (idempotent: a no-op when already
    # current), so a primary already on a clean `main` but behind origin is still
    # brought up — `already_on_canonical` only tells the caller whether a branch
    # switch is needed (and shapes the report line).
    def decision(state)
      branch   = (state["branch"]      || state[:branch]).to_s.strip
      dirty    = Array(state["dirty_files"] || state[:dirty_files]).map(&:to_s).reject(&:empty?)
      unpushed = Array(state["unpushed"]    || state[:unpushed]).map(&:to_s).reject(&:empty?)

      reasons = []
      reasons << "uncommitted changes (#{dirty.size} file(s))"           if dirty.any?
      reasons << "unpushed commits (#{unpushed.size} not on any remote)" if unpushed.any?

      if reasons.any?
        return {
          "action" => "refuse", "branch" => branch, "reasons" => reasons,
          "dirty_files" => dirty, "unpushed" => unpushed
        }
      end

      {
        "action" => "restore", "branch" => CANONICAL_BRANCH,
        "from_branch" => branch, "already_on_canonical" => (branch == CANONICAL_BRANCH)
      }
    end

    # True when a `decision` plan refuses to touch the checkout (work would be lost).
    def refuse?(plan)
      (plan["action"] || plan[:action]).to_s == "refuse"
    end

    # The loud, actionable abort text for a "refuse" plan — names the app, WHY
    # (the reasons), and the first offending files/commits, then the one-line fix.
    # Pure string building so it's unit-tested alongside the decision (mirrors
    # ShipSequence.preflight_message).
    def refusal_message(app, plan)
      reasons  = Array(plan["reasons"] || plan[:reasons])
      files    = Array(plan["dirty_files"] || plan[:dirty_files])
      unpushed = Array(plan["unpushed"] || plan[:unpushed])

      lines = ["refusing to restore #{app} primary checkout — it has local work a restore would discard:"]
      lines << "  reason: #{reasons.join('; ')}" if reasons.any?
      lines << "  uncommitted: #{sample(files)}" if files.any?
      lines << "  unpushed:    #{sample(unpushed)}" if unpushed.any?
      lines << "  Resolve by hand in the primary checkout (commit/push or stash/discard the changes), then re-run."
      lines.join("\n")
    end

    # --- internals -----------------------------------------------------------

    # First 5 entries joined, with a "(+N more)" tail when truncated.
    def sample(items)
      list = Array(items)
      head = list.first(5).join(", ")
      head + (list.size > 5 ? " (+#{list.size - 5} more)" : "")
    end
  end
end
