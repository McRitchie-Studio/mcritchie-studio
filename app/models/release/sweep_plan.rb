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
    #   "blocked" — [{ "slug", "repos", "missing" }] rows the sweep must REFUSE, and
    #              why: a multi-repo task whose PR urls cover only some of the repos
    #              it names (see #repo_coverage_gap). The caller aborts on a
    #              non-empty list — BEFORE the promote, so nothing has moved.
    def compute(rows)
      rows = Array(rows).map { |row| normalize(row) }

      blocked = rows.filter_map do |row|
        missing = repo_coverage_gap(repos: row["repos"], pr_repos: row["pr_urls"].keys,
                                    kind: row["kind"])
        next if missing.empty?

        { "slug" => row["slug"], "repos" => row["repos"], "missing" => missing }
      end
      blocked_slugs = blocked.map { |row| row["slug"] }
      rows = rows.reject { |row| blocked_slugs.include?(row["slug"]) }

      record = rows.select { |row| row["merged"] != "" }
      held   = rows.select { |row| row["merged"] == "" }

      {
        "record"  => record.map { |row| { "slug" => row["slug"], "merged" => row["merged"] } },
        "held"    => held.map { |row| row["slug"] },
        "sweep"   => record.map { |row| row["slug"] },
        "blocked" => blocked
      }
    end

    # THE INTERIM SAFETY NET, and the permanent rule it grew into: a task that names
    # more than one repo must have a recorded PR url for EVERY repo it names.
    #
    # On 2026-08-13 `land-rails-security-patch` named [mcritchie-studio,
    # turf-monster] and carried the hub's PR url — the only PR slot a task had.
    # Turf's PR #305 had nowhere to live, so `pr_url` became a lying single source:
    # the promote list, the member plan and every stage after it saw one repo, and
    # the task shipped while turf production still ran the unpatched code. There was
    # no signal anywhere in the run.
    #
    # So the sweep now REFUSES such a task and says which repo has no PR. A loud
    # refusal beats a silent half-ship: this alone would have stopped the incident at
    # the FIRST `prepare`, before anything was promoted, instead of after production
    # was wrong. The fix for a refusal is to record the missing PR
    # (`bin/task update <slug> --pr-url-for <repo>=<url>`) or, if the repo carries no
    # work, drop it from `devops.repositories`.
    #
    # A SINGLE-repo task is unaffected — it cannot lose a repo it never had a second
    # of — and a task with no declared repos at all is left to validate_members!,
    # which owns the "unknown repo" refusal.
    #
    # AND A GEM RELEASE IS EXEMPT (`kind == "gem"`), which is not a softening — it is
    # the difference between a missing record and an IMPOSSIBLE one. A `library`
    # task names its gem plus the CONSUMERS that adopt it, and a consumer's change in
    # a gem release is not written by a person at all: `bump_consumer_locks_for_qa`
    # commits each consumer's `Gemfile.lock` bump onto `release` during prepare.
    # There is no consumer PR to record, so demanding one would refuse every gem
    # release forever and teach operators to route around the guard. Measured, not
    # assumed: of the 21 multi-repo tasks on the board on 2026-08-14, the `library`
    # ones (guard-engine-migration-rollback naming four repos behind one gem PR;
    # fix-engine-migration-command; standardize-banner-placement) carry exactly this
    # shape. What still covers a gem member: validate_member_repos_known! judges
    # every repo it names, and Release::MemberEvidence refuses to STAMP a consumer
    # the run landed nothing for.
    def repo_coverage_gap(repos:, pr_repos:, kind: nil)
      return [] if kind.to_s == "gem"

      named = strings(repos)
      return [] if named.size < 2

      named - strings(pr_repos)
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

    # Row shape. `repo`/`pr_url` are the PRIMARY (singular) values kept for display
    # and crash-recovery; `repos`/`pr_urls` are the task's full release identity
    # (Task#release_repos / Task#release_pr_urls) and are what the coverage rule
    # reads. An older caller that emits only the singulars still normalizes: `repos`
    # falls back to the one repo, which the size<2 guard then passes. `kind` is the
    # member's Task#release_kind ("gem"/"app"/"unknown"), carried because the
    # coverage rule exempts a gem release (see #repo_coverage_gap); absent, it reads
    # as "" and the rule applies — the fail-CLOSED direction for an app.
    def normalize(row)
      {
        "slug"    => row["slug"].to_s,
        "stage"   => row["stage"].to_s,
        "merged"  => row["merged"].to_s,
        "pr_url"  => row["pr_url"].to_s,
        "repo"    => row["repo"].to_s,
        "kind"    => row["kind"].to_s,
        "repos"   => strings(row["repos"] || [ row["repo"] ]),
        "pr_urls" => normalize_map(row["pr_urls"], row["repo"], row["pr_url"])
      }
    end

    def normalize_map(map, primary_repo, primary_url)
      pairs = map.is_a?(Hash) ? map : {}
      pairs = { primary_repo.to_s => primary_url.to_s }.merge(pairs) if pairs.empty?
      pairs.to_h { |repo, url| [ repo.to_s.strip, url.to_s.strip ] }
           .reject { |repo, url| repo.empty? || url.empty? }
    end

    def strings(values)
      Array(values).map { |value| value.to_s.strip }.reject(&:empty?).uniq
    end
  end
end
