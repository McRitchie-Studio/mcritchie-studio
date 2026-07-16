class Release
  # The PURE per-task sweep decision behind `bin/release prepare`'s self-healing
  # sweep (and `bin/release merge`'s crash-recovery skip). Given the detected
  # candidate rows — each { "slug", "stage", "merged", "pr_url", "repo" } straight
  # off the board read — it partitions them into the members to RECORD onto the RC
  # versus the anomalies to leave behind.
  #
  # DevOps v2 accepted-ladder (Phase 3 Slice 4): review now MERGES each feat PR into
  # the `accepted` branch and stamps merged:"accepted", so by the time the sweep
  # runs every eligible member already carries its code on `accepted`. The sweep no
  # longer merges N per-task feat PRs — the CLI promotes ONE accepted→release batch
  # PR (promote_accepted_to_release!) — so this plan is purely "which members ride,
  # which are anomalies", NOT "which PRs to merge". The `merged` stamp IS the ticket:
  #   accepted/release/main → RECORD (code is on accepted or already past it),
  #   ""                    → HELD anomaly (a `reviewed` member with no code on
  #                           accepted — review's merge never landed; leave it
  #                           behind, the CLI warns, it self-heals on re-review).
  #
  # Like Release::ShipSequence / Release::MergePlan this is deliberately IO-free and
  # Rails-free (bin/release `require_relative`s it directly), so the partition lives
  # in ONE unit-tested place instead of inline shell logic. The CLI owns the
  # `gh`/`heroku` I/O around it.
  module SweepPlan
    module_function

    # Compute the sweep plan. Returns (all keys always present):
    #   "record" — [{ "slug", "merged" }] members to (re-)record onto the RC: their
    #              code is on `accepted` (merged "accepted") or already past it
    #              ("release"/"main" — the interrupted-run crash recovery). Order
    #              given. Release#add downgrades an "accepted" stamp to "release" as
    #              it attaches the member.
    #   "held"   — [slug] `reviewed` members with NO merged stamp: review's feat→
    #              accepted merge never landed, so there is no code on accepted to
    #              promote. Left off the sweep (they stay `reviewed`; the CLI warns).
    #              The invariant reviewed ⟺ code-on-accepted makes this a rare
    #              anomaly, not a routine "waiting on a PR" state.
    #   "sweep"  — [slug] every member to record membership for (= record), in order.
    def compute(rows)
      rows = Array(rows).map { |row| normalize(row) }

      record = rows.select { |row| row["merged"] != "" }
      held   = rows.select { |row| row["merged"] == "" }

      {
        "record" => record.map { |row| { "slug" => row["slug"], "merged" => row["merged"] } },
        "held"   => held.map { |row| row["slug"] },
        "sweep"  => record.map { |row| row["slug"] }
      }
    end

    # Assert a batch PR's base before the sweep merges it into `release`. In the
    # accepted-ladder the sweep opens/reuses ONE `--base release --head accepted`
    # batch PR (promote_accepted_to_release!), so the only valid base is `release`;
    # anything else is a real misconfiguration.
    #   release_branch → :proceed  (correct — merge as-is)
    #   anything else  → :abort
    # Pure/IO-free (the CLI owns the gh pr view around it). A blank base reads as
    # :abort — an unreadable base must never pass as release. (Phase 3 Slice 4
    # retired the :retarget arm: review merges feat→accepted, so there is no longer
    # an accepted-based feat PR for the sweep to retarget.)
    def base_action(base, release_branch)
      b = base.to_s.strip
      return :proceed if b == release_branch.to_s

      :abort
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
