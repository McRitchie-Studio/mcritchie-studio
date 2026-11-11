# frozen_string_literal: true

class Release
  # THE RELEASE PREFLIGHT (task release-preflight-hardening). Every check `bin/release
  # prepare` can make from reads alone, made BEFORE its first write: the presence
  # marker aside, before the confirm prompt, the role activity, the assembler claim,
  # the pin and the promote. One refusal line per finding, all of them at once, so
  # one run names everything the operator must fix.
  #
  # WHY (2026-11-10, two releases). The morning cycle refused at the multi-repo
  # coverage guard (a card naming 9 repos with PRs for 6), but only after it had
  # taken the assembler claim and opened Avi's activity. After the ship, the
  # containment check could not read voicebox's PRs: the App lacked the repo, and
  # nothing had asked before the release moved. Both were knowable at second one.
  #
  # FOUR CHECKS:
  #   1. coverage — a member card naming a repo with no PR (Release::SweepPlan's
  #      "blocked" rows, the 2026-08-13 half-ship shape);
  #   2. access — a release repo the running GitHub identity cannot read PRs in;
  #   3. desk slot — no free desk slot (the Redis band at its ceiling), so a
  #      fix-forward desk could not be cut mid-release;
  #   4. cwd — the run does not stand in the hub checkout.
  #
  # PURE and Rails-free: bin/release gathers the facts and require_relative's this.
  module Preflight
    module_function

    # The refusal lines, in check order. Empty means clear.
    #   blocked     — SweepPlan "blocked" rows: [{ "slug", "repos", "missing" }]
    #   unreadable  — [[repo, reason], ...] from ShipPrAccess.unreadable
    #   identity    — the GitHub identity the reads ran as
    #   free_slots  — Integer, or nil when the count could not be read (no refusal)
    #   cwd         — the run's working directory (real path)
    #   roots       — the checkout roots a release may stand in (real paths)
    def refusals(blocked:, unreadable:, identity:, free_slots:, cwd:, roots:)
      [
        *coverage_refusals(blocked),
        *access_refusals(unreadable, identity: identity),
        slot_refusal(free_slots),
        cwd_refusal(cwd, roots)
      ].compact
    end

    def coverage_refusals(blocked)
      Array(blocked).map do |row|
        missing = Array(row["missing"])
        "member #{row['slug']} names #{Array(row['repos']).size} repos but has no PR for " \
          "#{missing.size}: #{missing.join(', ')} — record each (`bin/task update #{row['slug']} " \
          "--pr-url-for <repo>=<url>`) or drop it (`bin/task update #{row['slug']} --remove-repo <repo>`)"
      end
    end

    def access_refusals(unreadable, identity:)
      Array(unreadable).map do |repo, why|
        "the GitHub App #{identity} cannot read #{repo} (#{why}) — Alex McRitchie grants it: GitHub → " \
          "McRitchie-Studio → Settings → GitHub Apps → #{identity} → Configure → add #{repo}, " \
          "Pull requests: Read-only"
      end
    end

    def slot_refusal(free_slots)
      return nil if free_slots.nil? || free_slots.to_i.positive?

      "no free desk slot (the Redis band is at its ceiling), so no fix-forward desk could be cut " \
        "mid-release — run `bin/agent-worktree cleanup --reclaim`, or `bin/agent-worktree scale --provision`"
    end

    def cwd_refusal(cwd, roots)
      here = cwd.to_s
      allowed = Array(roots).map(&:to_s).reject(&:empty?).uniq
      return nil if allowed.empty? || allowed.any? { |root| inside?(here, root) }

      "wrong cwd: #{here} is not the hub checkout (#{allowed.first}) — `cd #{allowed.first}` and run " \
        "the fixed-path script from there (the path picks the script, the cwd picks the tree)"
    end

    def inside?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    # Every repo the release would touch: each candidate's repos, then the active
    # release's. Order kept, blanks and repeats dropped.
    def release_repos(rows, active_repos = [])
      named = Array(rows).flat_map do |row|
        repos = Array(row["repos"]).map(&:to_s).reject(&:empty?)
        repos.empty? ? [row["repo"].to_s] : repos
      end
      (named + Array(active_repos).map(&:to_s)).map(&:strip).reject(&:empty?).uniq
    end

    # The abort text: a headline, then one `- ` line per refusal.
    def message(refusals)
      "release preflight refused (#{refusals.size}) — NOTHING was claimed, promoted, recorded or " \
        "deployed:\n  - " + refusals.join("\n  - ")
    end
  end
end
