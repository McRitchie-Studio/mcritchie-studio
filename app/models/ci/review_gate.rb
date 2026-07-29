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
    # The org every managed repo lives under (amcritchie/<repo>), overridable for a
    # fork/test — matches Ci::ProgressReader::DEFAULT_OWNER.
    DEFAULT_OWNER = ENV.fetch("GITHUB_REPO_OWNER", "amcritchie").freeze

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
      # app's "CI". Both reads below scope to the same name — a sha resolved from one
      # workflow must be folded from that same workflow, or a sibling workflow on the
      # same commit blends into the verdict.
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

      CiStatus.for_sha(nwo, sha, check_runs_payload(nwo, sha, workflow)).merge(sha: sha)
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

    # The ingested CI run for this head_sha, shaped as a check-runs payload for
    # CiStatus.for_sha — the head_sha → runs JOIN. Only the NEWEST run per SHA is
    # folded: a re-run makes a NEW workflow_run row (new run_id, same sha), and folding
    # a stale failed run beside the fresh green one would (correctly, for CiStatus)
    # read :red — but the fresh run is the live verdict, so the superseded row drops.
    def check_runs_payload(nwo, sha, workflow = CI_WORKFLOW)
      run = GithubWorkflowRun.for_repo(nwo)
                             .for_sha(sha)
                             .where(workflow_name: workflow)
                             .order(Arel.sql(LATEST_RUN_ORDER))
                             .first
      runs = if run
               [{ "name" => run.workflow_name.to_s, "status" => run.status.to_s, "conclusion" => run.conclusion.to_s }]
             else
               []
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
