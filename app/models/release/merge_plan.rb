class Release
  # Pure decision logic for the `bin/release merge` OVERLAP PLANNER. Like
  # Release::Cli / GemfileRepin / ShipSequence this is deliberately IO-free and
  # Rails-free: it takes the per-PR changed-file lists in and returns the
  # overlap report out, so the gh + git orchestration stays in bin/release and the
  # "which files collide / what order / who rebases" decision lives in ONE
  # unit-tested place. (bin/release `require_relative`s this file directly, so it
  # must load standalone with no Rails dependency.)
  #
  # Why it exists: when a batch of approved PRs merges into `release` back to back,
  # siblings that all touched the same hot files (task.rb, a shared helper, the
  # docs) conflict on `release` AFTER passing review — wasted rework that a
  # pre-merge heads-up prevents. The planner is WARNING-ONLY: it never blocks a
  # merge; it just shows the collisions, a suggested order, and who will rebase.
  module MergePlan
    module_function

    # Compute the overlap report for a batch of PRs given in the operator's
    # INTENDED merge order. `prs` is an array of string-keyed hashes:
    #   { "slug" => ..., "repo" => ..., "files" => [changed paths] }
    # Overlap is only meaningful WITHIN a repo (two repos can't share a working
    # tree), so every pairwise comparison is scoped to the same repo. Returns a
    # string-keyed hash (JSON-friendly):
    #   "overlaps"        => [{ "a" => slug, "b" => slug, "files" => [shared] }]
    #                        — same-repo pairs that touch ≥1 common file, listed in
    #                          the given order (a is the earlier-positioned slug).
    #   "suggested_order" => [slugs] — smallest-footprint-first (fewest changed
    #                          files), stable on ties; the order that tends to
    #                          shrink the rebase surface.
    #   "rebase"          => [slugs] — in the GIVEN order (what actually runs),
    #                          the PRs that share ≥1 file with an EARLIER-merged
    #                          same-repo PR, so they'll likely need a post-merge
    #                          rebase. The first PR to touch a file is never in it.
    def compute(prs)
      list = Array(prs).map { |pr| normalize(pr) }
      {
        "overlaps" => overlaps(list),
        "suggested_order" => suggested_order(list),
        "rebase" => rebase_needed(list)
      }
    end

    # Coerce a PR entry to the canonical shape: string slug/repo + a de-duped,
    # blank-stripped file list. Tolerates symbol OR string keys (the CLI builds
    # string keys after JSON; a direct unit test may pass either).
    def normalize(pr)
      h = pr || {}
      {
        "slug" => (h["slug"] || h[:slug]).to_s,
        "repo" => (h["repo"] || h[:repo]).to_s,
        "files" => Array(h["files"] || h[:files]).map(&:to_s).reject(&:empty?).uniq
      }
    end

    # Same-repo pairs that share ≥1 file, each listed once with the shared paths
    # sorted. `a` is whichever slug appears earlier in the given order.
    def overlaps(list)
      pairs = []
      list.each_with_index do |a, i|
        list[(i + 1)..].to_a.each do |b|
          next unless a["repo"] == b["repo"]

          shared = (a["files"] & b["files"]).sort
          pairs << { "a" => a["slug"], "b" => b["slug"], "files" => shared } if shared.any?
        end
      end
      pairs
    end

    # Smallest-footprint-first: fewest changed files merges first (a small,
    # focused PR is the cheapest to land and the least likely to broadly conflict),
    # ties broken by the given order (stable). The suggestion is advisory — the CLI
    # still merges in the order the operator passed.
    def suggested_order(list)
      list.each_with_index.sort_by { |pr, i| [pr["files"].size, i] }.map { |pr, _| pr["slug"] }
    end

    # In the GIVEN order, the PRs that will likely need a post-merge rebase: a PR
    # whose files intersect the union of files already "merged" by EARLIER same-repo
    # PRs. Tracks the merged-file set per repo so a cross-repo PR never falsely
    # flags. The first PR to touch any file is never flagged (nothing precedes it).
    def rebase_needed(list)
      merged = Hash.new { |h, repo| h[repo] = [] } # repo => files merged so far
      needs = []
      list.each do |pr|
        already = merged[pr["repo"]]
        needs << pr["slug"] if (pr["files"] & already).any?
        merged[pr["repo"]] = (already + pr["files"]).uniq
      end
      needs
    end
  end
end
