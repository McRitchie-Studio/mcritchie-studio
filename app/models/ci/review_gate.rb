# frozen_string_literal: true

module Ci
  # Is a submitted task's PR CI concluded GREEN? The server-side, DB-native answer
  # that lets POST /api/v1/tasks/claim_next_review pop only reviewable tasks whose CI
  # has finished green — the decision bin/pr-review used to assemble client-side from
  # a live `gh` read (CiStatus.evaluate on the pr_url) before spawning a reviewer.
  #
  # DATA SOURCE: our own ingested GitHub Actions rows (GithubWorkflowRun), never a
  # live `gh` call — so the pop is one fast board transaction, not N network reads.
  # The task's PR head_sha is resolved for FREE from the newest ingested `CI` workflow
  # run on its branch (exactly as Ci::ProgressReader.latest_ci_sha does for the
  # board's progress bars), then the CI run(s) FOR THAT SHA are folded into a verdict.
  #
  # VERDICT SEMANTICS are CiStatus's, reused verbatim (bin/lib/ci_status.rb — the
  # SHA-addressed `for_sha` fold) rather than re-implemented, so this review gate and
  # the dor-check / pr-review merge gates can never DRIFT on what "green" means (that
  # module's own comments show how subtle the fold is). We feed the ingested rows
  # through CiStatus's documented INJECTION seam — a check-runs payload, the same seam
  # its unit tests drive — so nothing here ever shells out to `gh`.
  #
  # Only :green is eligible. :red / :pending / :none / :ci_less / :unverified are all
  # "not green", and the caller SKIPS them — a non-green PR is never claimed for review.
  #
  # EVERY REPO THE TASK HAS A PR IN GETS A VOTE, and :green means ALL of them are.
  # This gate used to read `repositories.first` (#repo_for) — one repo, silently — so
  # a task landing PRs in two repos was popped for review, and AUTO-MERGED by
  # Review::PendingActionExecutor, on repo #1's CI alone while repo #2 was red. The
  # merge is the sharp end: it is the one path with no human between a bad verdict and
  # `accepted`. #repos_for is now the whole question, #verdict folds it, and the
  # singular reader is gone rather than left for the next caller to pick up.
  module ReviewGate
    # Resolved PER REPO — an app repo's runs are named "CI", a gem's are its own
    # suite ("Engine CI"). Hard-coding the app literal here is what made every
    # studio-engine PR unclaimable. See GithubWorkflowRun.ci_workflow_for.
    CI_WORKFLOW = GithubWorkflowRun::CI_WORKFLOW
    # Newest-run ordering, mirroring Ci::ProgressReader::LATEST_RUN_ORDER.
    LATEST_RUN_ORDER = "run_started_at DESC NULLS LAST, created_at DESC, run_id DESC"
    # The org every managed repo lives under (McRitchie-Studio/<repo>), overridable
    # for a fork/test — matches Ci::ProgressReader::DEFAULT_OWNER.
    DEFAULT_OWNER = ENV.fetch("GITHUB_REPO_OWNER", "McRitchie-Studio").freeze

    module_function

    # Is this task's PR CI concluded-green — in EVERY repo it has a PR in? `injected`
    # is the test seam — a bare CiStatus token ("green"/"red"/"pending"/"none"/…)
    # applied AS the verdict — so a rank/skip unit test drives green vs. not-green per
    # task without ingesting any GithubWorkflowRun rows.
    def green?(task, injected: nil)
      verdict(task, injected: injected)[:state] == :green
    end

    # The task's PR CI verdict, a Hash `{ state:, sha:, repo:, repos: }`:
    #   :no_pr — the task carries no PR/branch yet (nothing to gate on)
    #   :none  — a PR exists but no CI run has been ingested for its head
    #   otherwise — CiStatus's SHA-addressed fold (:green / :red / :pending / …)
    #
    # ACROSS EVERY REPO in #repos_for, folded by #fold_repos: :green only when they
    # ALL are. `repo:` names the repo whose state this verdict is reporting and
    # `repos:` carries the whole `{ repo => verdict }` map, so a caller can say WHICH
    # repo stopped it instead of "the CI" — the difference between a merge that
    # explains itself and one that silently did not happen.
    #
    # `repo:` (the argument) asks about ONE repo instead of folding. That is the
    # head-sha PIN's read: an armed merge is pinned to one PR in one repo, so the sha
    # it compares must come from THAT repo's runs, while the green/not-green question
    # it asks first spans them all. Two different questions, and answering both with
    # one repo's verdict is the whole of this defect.
    def verdict(task, repo: nil, injected: nil)
      require_ci_status
      token = injected.to_s.strip
      return { state: token.to_sym } if CiStatus::TOKENS.include?(token)
      return repo_verdict(task, repo) if repo.present?

      repos = repos_for(task)
      return { state: :no_pr } if repos.empty?

      fold_repos(repos.index_with { |name| repo_verdict(task, name) })
    end

    # ONE repo's CI verdict — the read this gate has always done, now named and
    # called once per PR-bearing repo.
    def repo_verdict(task, repo)
      repo = bare_slug(repo)
      nwo = nwo_for(repo)
      branch = branch_for(task)
      return { state: :no_pr, repo: repo } if nwo.empty? || branch.empty? || task.devops_url("pr").blank?

      # Resolved from the REPO, not assumed: a gem's runs are named "Engine CI", an
      # app's "CI".
      #
      # IT SCOPES THE TREE, NOT THE VERDICT — the two are different questions, and
      # answering both with this one name is the defect task
      # autopilot-merges-on-pending fixed. WHICH TREE do we hold CI for is the suite
      # workflow's to answer (latest_ci_sha): a downstream "Consumer CI" run alone
      # resolves no tree, which is why a gem PR carrying only that reads :none. WHICH
      # RUNS get a vote on that tree is a question about the COMMIT, and every run
      # GitHub started on it answers (check_runs_payload) — a lane silently dropped
      # from the fold is how a merge fired against a still-running consumer suite.
      workflow = GithubWorkflowRun.ci_workflow_for(repo)

      # FAIL CLOSED on an unresolved workflow. A repo with no declared suite (or one
      # missing from GEM_CI_WORKFLOWS) must read :none — NEVER "match any workflow on
      # the branch". Dropping the filter here let unrelated runs authorise a merge:
      # a FAILED `CI` run plus a later successful `Lint` run on the SAME head_sha
      # folded to :green, because the newest unrelated pass masked the real failure.
      # This gate authorises merges; a display reader may guess, this may not.
      return { state: :none, sha: nil, repo: repo } if workflow.blank?

      sha = latest_ci_sha(nwo, branch, workflow)
      return { state: :none, sha: nil, repo: repo } if sha.blank?

      CiStatus.for_sha(nwo, sha, check_runs_payload(nwo, sha)).merge(sha: sha, repo: repo)
    end

    # The newest ingested `CI` run's head_sha on this repo+branch — the PR tip we hold
    # CI data for (mirrors Ci::ProgressReader.latest_ci_sha). nil when none ingested.
    # `workflow` is always present — #verdict returns :none before calling this when it
    # cannot resolve one, so the filter is never silently dropped.
    def latest_ci_sha(nwo, branch, workflow = CI_WORKFLOW)
      GithubWorkflowRun.for_repo(nwo)
                       .where(head_branch: branch, workflow_name: workflow)
                       .order(Arel.sql(LATEST_RUN_ORDER))
                       .limit(1)
                       .pick(:head_sha)
    end

    # EVERY ingested run for this head_sha, shaped as a check-runs payload for
    # CiStatus.for_sha — the head_sha → runs JOIN. One vote per WORKFLOW, and the
    # vote is that workflow's NEWEST run.
    #
    # THIS READ IS SHA-SCOPED, NOT WORKFLOW-SCOPED, and the distinction is the whole
    # of task autopilot-merges-on-pending. It used to return exactly ONE row — the
    # newest run whose workflow_name matched the repo's resolved suite — so any OTHER
    # lane GitHub ran on the same tree was dropped before CiStatus ever saw it.
    #
    # MEASURED (studio-engine PR #111, 2026-08-13). GitHub queued two runs on head
    # 2d50675 at 21:02:07Z: `Engine CI` concluded success at 21:03:47Z, `Consumer CI`
    # at 21:09:36Z. An armed merge fired at 21:06:02Z, between the two. The gate was
    # not wrong about what it read; it was handed one completed success and asked
    # whether THAT was green. A dropped lane is not a pending lane — it is a lane
    # with no vote, and the verdict came back green about a question it never asked.
    # `count: 1` on a six-lane tree was the standing tell.
    #
    # WHAT WAS ALREADY RIGHT, so the fix does not touch it: CiStatus.fold is
    # positively framed (:green iff EVERY run affirmatively passed or skipped) and
    # CiStatus.check_run_bucket fail-safes any status short of `completed` — and any
    # conclusion it does not recognise — to `pending`. Feed those two the whole set
    # and "red, pending, cancelled all do nothing" holds on its own.
    #
    # NEWEST PER WORKFLOW, not newest overall and not every row. A SHA can carry
    # several DISTINCT runs of the SAME workflow (a re-triggered suite), and folding
    # a stale failed attempt beside its fresh green one would read :red forever. A
    # RE-RUN is not one of those cases: GitHub re-runs under the SAME run_id, bumping
    # `run_attempt` on the one row, and the ingest advances that row's conclusion with
    # its attempt — so this fold sees the live verdict.
    #
    # AN UNRELATED LANE NOW BLOCKS rather than being ignored, and that is the intended
    # direction. This gate authorises an UNATTENDED merge, so a run we cannot account
    # for must cost a delayed merge (the action stays pending and retries until its
    # TTL), never an unverified one. Narrowing it again needs GitHub's required-check
    # set, which the board does not ingest — a guess about which lanes matter is how
    # the dropped lane got dropped.
    #
    # STILL NOT COVERED, stated so nobody reads more into this than it does: a lane
    # that has produced NO ROW AT ALL is invisible here, because absence of a row and
    # absence of a workflow are the same thing in this table. The exposure is small in
    # practice — GitHub delivers `workflow_run` at QUEUE time (STATUS_ORDER's
    # "queued"), and in the incident above both runs were queued in the same second —
    # but it is real, and it is why guards 10-13 in Review::PendingActionExecutor
    # re-read the tree from GitHub itself rather than trusting this table alone.
    def check_runs_payload(nwo, sha)
      runs = GithubWorkflowRun.for_repo(nwo)
                              .for_sha(sha)
                              .order(Arel.sql(LATEST_RUN_ORDER))
                              .to_a
                              .group_by { |run| run.workflow_name.to_s }
                              .map { |_name, group| group.first }
                              .map do |run|
                                { "name" => run.workflow_name.to_s, "status" => run.status.to_s,
                                  "conclusion" => run.conclusion.to_s }
                              end
      { "total_count" => runs.size, "check_runs" => runs }.to_json
    end

    # N PER-REPO VERDICTS → ONE, positively framed exactly like CiStatus.fold:
    # :green only when EVERY repo affirmatively read green. Anything else is decided
    # by ONE repo and says which — a :red first (it outranks a :pending here for the
    # same reason it does inside a single repo's fold: red is the actionable one),
    # otherwise the first repo in order that is not green. That repo's own state,
    # `failing`/`pending` lane names and `sha` ride out unchanged, so every existing
    # reader of this hash keeps working on a single-repo task, where this returns
    # that one repo's verdict plus `repos:`.
    #
    # `count` is SUMMED on green — the lanes that voted, across the whole task. It is
    # the direct reading of "everything voted", and a one-repo task is unaffected
    # (the sum of one). Summed only when every repo reported one, so a partial count
    # never reads as a total.
    def fold_repos(per_repo)
      primary = per_repo.keys.first
      unless per_repo.each_value.all? { |verdict| verdict[:state] == :green }
        decided = per_repo.find { |_, verdict| verdict[:state] == :red } ||
                  per_repo.find { |_, verdict| verdict[:state] != :green }
        return decided.last.merge(repos: per_repo)
      end

      counts = per_repo.each_value.map { |verdict| verdict[:count] }.compact
      folded = per_repo[primary].merge(repos: per_repo)
      counts.size == per_repo.size ? folded.merge(count: counts.sum) : folded
    end

    # EVERY repo this task owes a CI verdict in: the repos it has actually RECORDED A
    # PR IN — the primary `devops.pr_url`'s repo first, then the rest of the per-repo
    # register (`devops.pr_urls`, via Task#release_pr_urls) in name order.
    #
    # THE PR REGISTER, NOT `devops.repositories`, and that choice is load-bearing in
    # both directions:
    #
    #   * A repo the task NAMES but has no PR in owes NOTHING. A gem task names its
    #     CONSUMER repos so the pipeline can reason that the gem alone owes the PR
    #     (Task#pr_bearing_repositories) — the gem-release path, and the case that
    #     refuted forbidding multi-repo tasks outright. Those repos have no branch and
    #     no runs, so demanding a verdict for one would read :none forever and strand
    #     every engine release. This is the same predicate `bin/dor-check` grades
    #     CERTS with (`cert_owing_repos`, task cert-gate-loses-multi-repo): a recorded
    #     PR owes evidence, a named-but-PR-less repo does not.
    #
    #   * A repo the task has a PR in but never NAMED still owes one. That is where
    #     this deliberately reads WIDER than the cert gate's `declared & pr_bearing`
    #     intersection, and the reason the two differ is the cost of a miss on each
    #     side: the cert gate intersects because it must FIND that repo's tree on this
    #     machine and cannot always, while a CI verdict is a DB read that always
    #     works. `bin/task update --pr-url-for <repo>=<url>` writes the register
    #     WITHOUT touching `repositories`, so an undeclared PR-bearing repo is one
    #     command away — and letting it through ungated is the exact silent pass this
    #     gate exists to close.
    #
    # EMPTY without a primary `pr_url`, which keeps :no_pr meaning what it always did:
    # the review lane acts on that one PR, and a task with no PR is not a review
    # target however many entries its register holds.
    #
    # ONE BRANCH NAME SERVES EVERY REPO (`devops.branch`, the `feat/<slug>` convention
    # the whole pipeline builds on — bin/dor-check roots the same way). A PR pushed to
    # a differently-named branch in a second repo resolves no run there and reads
    # :none, which blocks rather than passes.
    def repos_for(task)
      primary = primary_repo_for(task)
      return [] if primary.empty?

      register = task.respond_to?(:release_pr_urls) ? task.release_pr_urls : {}
      others = register.keys.map { |repo| bare_slug(repo) }.reject { |repo| repo.empty? || repo == primary }
      [primary] + others.uniq.sort
    end

    # The repo under review: the one the task's PR url names, since that is the PR
    # the review lane acts on. Falls back to the first declared repo ONLY when the
    # url names none (a malformed or non-GitHub `pr_url`) — that fallback is the
    # gate's old behaviour, kept so a task with an unparseable url still reads the
    # repo it always did instead of silently becoming :no_pr.
    #
    # Preferring the URL is itself a fix: a gem task naming its consumers
    # (`repositories` => [mcritchie-studio, turf-monster], `pr_url` => a studio-engine
    # PR) resolved `mcritchie-studio` here and read the HUB's runs for a branch that
    # only exists in the gem — :none, forever unclaimable.
    def primary_repo_for(task)
      url = task.devops_url("pr").to_s.strip
      return "" if url.empty? # no PR — the :no_pr verdict, and nothing to gate

      bare_slug(Task.repo_from_pr_url(url)).presence || bare_slug(Array(task.devops_repositories).first)
    end

    # A bare repo slug from a slug, an owner-qualified name, or either with padding —
    # so `turf-monster` and `McRitchie-Studio/turf-monster` are one repo and never
    # gated twice. (#nwo_for puts the owner back on for the query.)
    def bare_slug(value)
      value.to_s.strip.split("/").last.to_s.strip
    end

    def branch_for(task)
      task.devops_field("branch").to_s
    end

    # "owner/repo" for the GithubWorkflowRun `repo` column (stored full-name), from a
    # bare repo slug or a value already carrying an owner.
    def nwo_for(repo)
      repo = repo.to_s.strip
      return "" if repo.empty?
      return repo if repo.include?("/")

      "#{DEFAULT_OWNER}/#{repo}"
    end

    # Load the CLI verdict library on first use (idempotent). It is a plain module —
    # `require "json"` / `require "shellwords"`, no Rails deps, no load-time side
    # effects — so requiring it here is safe; kept lazy so eager-load never pulls bin/
    # code at boot. lib/task_usage_sandbox.rb sets the precedent for reaching bin/lib.
    def require_ci_status
      require Rails.root.join("bin", "lib", "ci_status.rb").to_s
    end
  end
end
