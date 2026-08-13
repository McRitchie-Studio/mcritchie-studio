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

    # Is this task's PR CI concluded-green? `injected` is the test seam — a bare
    # CiStatus token ("green"/"red"/"pending"/"none"/…) applied AS the verdict — so a
    # rank/skip unit test drives green vs. not-green per task without ingesting any
    # GithubWorkflowRun rows.
    def green?(task, injected: nil)
      verdict(task, injected: injected)[:state] == :green
    end

    # The task's PR CI verdict, a Hash `{ state:, sha: }`:
    #   :no_pr — the task carries no PR/branch yet (nothing to gate on)
    #   :none  — a PR exists but no CI run has been ingested for its head
    #   otherwise — CiStatus's SHA-addressed fold (:green / :red / :pending / …)
    def verdict(task, injected: nil)
      require_ci_status
      token = injected.to_s.strip
      return { state: token.to_sym } if CiStatus::TOKENS.include?(token)

      repo = repo_for(task)
      nwo = nwo_for(repo)
      branch = branch_for(task)
      return { state: :no_pr } if nwo.empty? || branch.empty? || task.devops_url("pr").blank?

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
      return { state: :none, sha: nil } if workflow.blank?

      sha = latest_ci_sha(nwo, branch, workflow)
      return { state: :none, sha: nil } if sha.blank?

      CiStatus.for_sha(nwo, sha, check_runs_payload(nwo, sha)).merge(sha: sha)
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

    def repo_for(task)
      Array(task.devops_repositories).first.to_s
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
