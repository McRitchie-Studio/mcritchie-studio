class Release
  # The PURE per-task sweep decision behind `bin/release prepare`'s self-healing
  # sweep (and `bin/release merge`'s crash-recovery skip). Given the detected
  # candidate rows — each { "slug", "stage", "merged", "pr_url", "repo" } straight
  # off the board read — it decides, per task, whether the CLI must `gh pr merge`
  # its PR, can SKIP the merge (its PR already rides `release`/`main` — the
  # `merged` crash-recovery signal), or must LEAVE it behind (no PR to merge).
  #
  # Like Release::ShipSequence / Release::MergePlan this is deliberately IO-free
  # and Rails-free (bin/release `require_relative`s it directly), so the
  # merge/skip/leave decision lives in ONE unit-tested place instead of inline
  # shell logic. The CLI owns the `gh`/`heroku` I/O around it.
  module SweepPlan
    module_function

    # Compute the sweep plan. Returns (all keys always present):
    #   "merge"       — [{ "pr_url", "slugs" }] the unique PRs to `gh pr merge`,
    #                   grouped (several task records may ride one PR), in the
    #                   order given.
    #   "skip"        — [{ "slug", "merged" }] tasks whose PR is ALREADY on the
    #                   release branch (merged "release") or past it ("main") —
    #                   the interrupted-run recovery: never re-merge, just
    #                   (re-)record membership.
    #   "unmergeable" — [slug] tasks with NO pr_url and NO merged stamp: nothing
    #                   to merge, so they are left off the sweep (they stay
    #                   `reviewed`; the CLI warns).
    #   "sweep"       — [slug] every task to record membership for (skip + merge
    #                   groups), in the order given.
    def compute(rows)
      rows = Array(rows).map { |row| normalize(row) }

      skip        = rows.select { |row| row["merged"] != "" }
      to_merge    = rows.select { |row| row["merged"] == "" && row["pr_url"] != "" }
      unmergeable = rows.select { |row| row["merged"] == "" && row["pr_url"] == "" }

      {
        "merge"       => group_by_pr(to_merge),
        "skip"        => skip.map { |row| { "slug" => row["slug"], "merged" => row["merged"] } },
        "unmergeable" => unmergeable.map { |row| row["slug"] },
        "sweep"       => (skip + to_merge).map { |row| row["slug"] }
      }
    end

    # The unique PRs to merge, grouped by pr_url in first-appearance order —
    # several task records may intentionally ride one PR, which is checked and
    # merged ONCE while every rider is swept.
    def group_by_pr(rows)
      Array(rows).group_by { |row| row["pr_url"] }.map do |pr_url, group|
        { "pr_url" => pr_url, "slugs" => group.map { |row| row["slug"] } }
      end
    end

    def normalize(row)
      {
        "slug"   => row["slug"].to_s,
        "stage"  => row["stage"].to_s,
        "merged" => row["merged"].to_s,
        "pr_url" => row["pr_url"].to_s,
        "repo"   => row["repo"].to_s
      }
    end
  end
end
