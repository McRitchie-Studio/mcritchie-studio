# frozen_string_literal: true

require "timeout"

module Ci
  # Reads GitHub CI check progress for a commit and folds it into a
  # Ci::CheckProgress (passed / total / state) for the board's progress bars.
  #
  # DATA SOURCE (two paths, live-first): for a SHA whose per-job progress the
  # `workflow_job` webhook has already recorded (CiCheckJob rows), we fold THOSE —
  # a free DB read, no network, and the same rows a live Turbo push re-renders as
  # each check settles (v1.1). Only a SHA with NO ingested jobs — a task whose CI
  # predates the webhook subscription, or a run whose first job event has not landed
  # — falls back to the render-time, SHA-addressed check-runs read via the in-app
  # Github::Client, wrapped in Rails.cache so the board makes at most one API call
  # per SHA per TTL window regardless of how many viewers or cards ask.
  #
  # The SHA itself is resolved for FREE from the already-ingested `GithubWorkflowRun`
  # webhook rows (a task's branch tip; the `release` branch tip) — so even the
  # fallback hits GitHub only for the per-check counts, and only once a CI run exists.
  #
  # This touches nothing the release conductor / sweep own: it READS CI state (from
  # our own webhook rows or GitHub), it never emits progress from the pipeline.
  #
  # DEGRADES TO BLANK, ALWAYS: no PR, no CI run, no token, an unreadable payload,
  # a slow/hung API, or any error -> Ci::CheckProgress.blank (the bar renders
  # nothing). Every rescue lands in ErrorLog (backend discipline).
  class ProgressReader
    # The org every managed repo lives under (McRitchie-Studio/<repo>), overridable
    # for a fork/test.
    DEFAULT_OWNER = ENV.fetch("GITHUB_REPO_OWNER", "McRitchie-Studio").freeze

    # The repo whose `release` branch tip carries the G3 candidate suite CI run.
    # Retained for the task-card fallback repo; the release meter now reads EVERY
    # member repo (see for_release), not just the hub.
    HUB_REPO = "mcritchie-studio"

    # A GEM member has no `release` branch (two-rung ladder), so its release-candidate
    # verdict is its OWN suite CI on `main`. GEM_CI_WORKFLOWS pins WHICH workflow that
    # is per gem — studio-engine also runs a "Consumer CI" on main (the downstream
    # apps' suites), which is NOT the gem's own verdict, so the name filter is
    # load-bearing. A gem absent from this map resolves the newest `main` run of any
    # workflow (solana-studio ships none → a blank, invisible track).
    # Sourced from GithubWorkflowRun — the ONE place a repo's CI workflow name is
    # decided — so the reader, the ingest, and Ci::ReviewGate can no longer drift
    # apart. Kept as a named constant here because this is the release-track reader's
    # documented vocabulary and callers/tests reference it.
    GEM_CI_WORKFLOWS = GithubWorkflowRun::GEM_CI_WORKFLOWS
    GEM_CI_BRANCH = "main"

    # Which stages can show a CI bar. BUILDING is in the list because `bin/ship`
    # opens the PR and then WAITS for its CI (gate-submit-on-green-ci) while the task
    # is still building — the ~12 minutes an operator most wants to watch tick. It is
    # a stage gate, not the whole test: eligible_task? still demands a pr_url AND a
    # branch, so an ordinary building task (no PR yet) resolves blank exactly as
    # before. Past `submitted` the run is history, so the bar stops at `assembled`.
    TASK_STAGES_WITH_CI = %w[building submitted reviewed assembled].freeze

    # Newest-run ordering — the canonical run-recency sort (Ci::ReviewGate mirrors it).
    LATEST_RUN_ORDER = "run_started_at DESC NULLS LAST, created_at DESC, run_id DESC"

    # Render-path budget: a cold GitHub call may never stall the board for long.
    REQUEST_BUDGET_SECONDS = ENV.fetch("CI_PROGRESS_REQUEST_BUDGET", 5).to_f

    # Cache windows: an in-flight run may have moved seconds ago; a settled one is
    # immutable, so hold it long enough to spare the API without going stale.
    LIVE_TTL = 30.seconds
    TERMINAL_TTL = 10.minutes

    def initialize(client: nil, cache: Rails.cache, fixtures: nil, clock: Time)
      @client = client
      @cache = cache
      @fixtures = fixtures || env_fixtures
      @clock = clock
    end

    # A task's PR-head CI progress, or blank. Reused by the single-card broadcast
    # path; the board uses the batched `progress_by_slug` to avoid N+1.
    def for_task(task)
      return CheckProgress.blank unless eligible_task?(task)

      nwo, branch, workflow, repo = task_ci_target(task)
      sha = latest_ci_sha(nwo, branch, workflow)
      return CheckProgress.blank unless sha

      task_progress(nwo, repo, sha, workflow)
    end

    # Batched: { slug => Ci::CheckProgress } for every eligible task, resolving all
    # branch tips in ONE query. Non-eligible tasks are simply absent from the map.
    def progress_by_slug(tasks)
      eligible = Array(tasks).select { |task| eligible_task?(task) }
      return {} if eligible.empty?

      targets = eligible.to_h { |task| [task.slug, task_ci_target(task)] }
      shas = latest_ci_shas(targets.values)
      eligible.each_with_object({}) do |task, memo|
        nwo, branch, workflow, repo = targets[task.slug]
        sha = shas[[nwo, branch, workflow]]
        next unless sha

        memo[task.slug] = task_progress(nwo, repo, sha, workflow)
      end
    end

    # The G3 candidate suite CI, decomposed ONE TRACK PER MEMBER REPO: a release
    # spanning turf-monster + mcritchie-studio yields two entries, +studio-engine
    # three — one per app whose code is actually in the release. Returns an ordered
    # { repo_slug => Ci::CheckProgress } (producer-first, mirroring ordered_members),
    # or {} when the release is not active.
    #
    # Each repo reads its OWN release-candidate CI run, resolved by ci_target_for:
    #   * an APP repo — the `name: "CI"` run on the swept `release` branch tip
    #     (already per-repo: each app is its own GitHub repo and each runs CI on
    #     push:release, ingested into GithubWorkflowRun/CiCheckJob keyed on repo+sha);
    #   * a GEM repo — its own two-rung suite on `main` (studio-engine's "Engine CI"),
    #     since a gem has no `release` branch.
    #
    # Every member repo gets an ENTRY even with no ingested run yet — a blank
    # CheckProgress (renders an empty, zero-height slot) — so the live #dom_id target
    # exists before that repo's first check settles and the broadcaster can morph it in.
    def for_release(release)
      return {} unless release.respond_to?(:active?) && release.active?

      member_repos(release).index_with do |repo|
        nwo, branch, workflow = ci_target_for(repo)
        sha = branch.present? ? latest_ci_sha(nwo, branch, workflow) : nil
        # Scope the fold to the target workflow — a gem's `main` SHA carries a sibling
        # "Consumer CI" the gem track must not blend in.
        sha ? for_sha(nwo, sha, workflow) : CheckProgress.blank
      end
    end

    # The ONE release-CI track a `workflow_job` on (nwo, branch) affects, as
    # [repo_slug, Ci::CheckProgress], or nil — the live broadcaster's fan-out unit, so
    # a single job event morphs JUST that repo's G3 track. Fires only when nwo is a
    # MEMBER repo of the active release AND `branch` is the branch that repo's track
    # reads (app → `release`, gem → `main`), so a hub `main` push — whose release track
    # lives on `release` — never triggers a release-CI morph on the wrong branch.
    def release_ci_slot_for(release, nwo, branch)
      return nil unless release.respond_to?(:active?) && release.active?

      repo = repo_slug(nwo)
      return nil unless member_repos(release).include?(repo)

      target_nwo, target_branch, workflow = ci_target_for(repo)
      return nil unless branch.to_s == target_branch

      sha = latest_ci_sha(target_nwo, target_branch, workflow)
      [repo, sha ? for_sha(target_nwo, sha, workflow) : CheckProgress.blank]
    end

    # The GitHub Actions run URL for a repo's release-candidate CI track, or nil — the
    # html_url the Next Release card's G3 track links to. Resolves the SAME run
    # for_release folds its progress from (ci_target_for's [nwo, branch, workflow], the
    # newest ingested run on that branch+workflow), then reads that run's html_url from
    # the already-ingested GithubWorkflowRun rows — no network. nil when the release is
    # inactive or no run is ingested yet, so the track renders UNLINKED (never an
    # href="#"). Same ordering as latest_ci_sha, so the URL points at the EXACT run
    # whose SHA drove that track's progress.
    def release_ci_run_url(release, repo)
      return nil unless release.respond_to?(:active?) && release.active?

      nwo, branch, workflow = ci_target_for(repo)
      latest_ci_run_url(nwo, branch, workflow)
    end

    # The deploy workflow whose newest run each release PHASE resolves — keyed by the
    # tracker phase ("qa" -> Deploying QA node, "prod" -> Deploying node) to the GitHub
    # Actions workflow DISPLAY NAME (the run's `name`, what GithubWorkflowRun stores).
    # config/release_repos.yml names the FILE (qa-deploy.yml / prod-deploy.yml); these
    # are their `name:` headers. A repo that deploys some other way just has no matching
    # run, so its node renders unlinked.
    DEPLOY_RUN_WORKFLOWS = {
      "qa"   => ["QA Deploy"].freeze,
      "prod" => ["Production Deploy"].freeze
    }.freeze

    # The GitHub Actions DEPLOY-run URL for a release PHASE ("qa"/"prod"), or nil — the
    # html_url the Next Release card's "Deploying QA" / "Deploying" tracker nodes link
    # to. Unlike the G3 CI links (a push:release run keyed on branch+SHA), a deploy is a
    # `workflow_dispatch` run whose head_branch/head_sha are the dispatch ref, NOT the
    # release tip — so it is keyed on the workflow's DISPLAY NAME instead. Scoped to the
    # release's member repos, newest run wins (the active release's deploy is the most
    # recent). nil -> the node renders unlinked, never a broken href — the same graceful
    # contract as release_ci_run_url, and safe from an already-ingested read (no network).
    def release_deploy_run_url(release, phase)
      return nil if release.blank?

      workflow_names = DEPLOY_RUN_WORKFLOWS[phase.to_s]
      return nil if workflow_names.blank?

      nwos = member_repos(release).filter_map { |repo| nwo_for(repo).presence }.uniq
      return nil if nwos.empty?

      GithubWorkflowRun.where(repo: nwos, workflow_name: workflow_names)
                       .order(Arel.sql(LATEST_RUN_ORDER))
                       .limit(1).pick(:html_url).presence
    end

    # The newest DEPLOY run for ONE repo + phase, as { status:, conclusion:, url: } or
    # nil — the per-lane signal the new per-repo tracker fills its QA / Deploying meters
    # from (coarse: queued/in_progress/completed → pending/running/done). Same
    # workflow-DISPLAY-name keying as release_deploy_run_url, but scoped to a single repo
    # so each lane reads its own deploy, not the release-wide newest.
    def release_deploy_run(release, repo, phase)
      return nil if release.blank? || repo.to_s.strip.empty?

      workflow_names = DEPLOY_RUN_WORKFLOWS[phase.to_s]
      nwo = nwo_for(repo)
      return nil if workflow_names.blank? || nwo.to_s.empty?

      row = GithubWorkflowRun.where(repo: nwo, workflow_name: workflow_names)
                             .order(Arel.sql(LATEST_RUN_ORDER))
                             .limit(1).pick(:status, :conclusion, :html_url)
      return nil if row.blank?

      { status: row[0], conclusion: row[1], url: row[2].presence }
    end

    # The core read: SHA -> Ci::CheckProgress. Live-first — a SHA the `workflow_job`
    # webhook has recorded folds straight from CiCheckJob rows (no network); only a
    # SHA with no ingested jobs falls back to the cached, budgeted GitHub API read.
    #
    # `workflow_name` SCOPES the fold to one workflow (the gem path — see for_release).
    # It is load-bearing in TWO places: the live fold filters CiCheckJob to that
    # workflow, AND the API fallback is REFUSED for any scoped workflow other than
    # `CI`. The check-runs API is workflow-BLIND — it returns every workflow's checks
    # on the SHA — so falling back to it for a gem would re-introduce the exact
    # blending the scope exists to prevent (a failing "Consumer CI" dragging the gem's
    # "Engine CI" track red). `CI` is the one safe fallback: it is the only workflow on
    # the branches an app track reads, so the blind API cannot blend anything there.
    def for_sha(nwo, sha, workflow_name = nil)
      nwo = nwo.to_s
      sha = sha.to_s
      return CheckProgress.blank if nwo.empty? || sha.empty?
      return fixture_progress(sha) if fixture?(sha)

      live = live_progress(nwo, sha, workflow_name)
      return live if live&.present?

      # A workflow-scoped read for anything but CI must not fall back to the blind API.
      return CheckProgress.blank(sha: sha) if workflow_name.present? && workflow_name != GithubWorkflowRun::CI_WORKFLOW

      cache_key = "ci:progress:#{nwo}:#{sha}"
      cached = @cache.read(cache_key)
      return cached if cached.is_a?(CheckProgress)

      progress = fetch_progress(nwo, sha)
      @cache.write(cache_key, progress, expires_in: progress.pending? ? LIVE_TTL : TERMINAL_TTL)
      progress
    end

    # The tasks on a repo+branch whose CI bar this webhook event affects — the
    # broadcast fan-out target (usually 0 or 1). Reuses the exact eligibility +
    # repo/branch resolution the render path uses, so a live push and a page load
    # agree on which cards carry a bar. The candidate set is TASK_STAGES_WITH_CI
    # (building through assembled) — the live desks plus the deploy queue, a handful
    # of rows, not the whole board.
    def eligible_tasks_for(nwo, branch)
      nwo = nwo.to_s
      branch = branch.to_s
      return [] if nwo.empty? || branch.empty?

      Task.where(stage: TASK_STAGES_WITH_CI).select do |task|
        eligible_task?(task) && nwo_for(task_repo(task)) == nwo && task_branch(task) == branch
      end
    end

    private

    # Live per-SHA progress folded from the CiCheckJob rows the `workflow_job`
    # webhook records — the push-driven path. nil (NOT blank) when no rows exist yet,
    # so for_sha falls THROUGH to the cached API read rather than showing an empty bar
    # for a SHA whose jobs simply have not been ingested. Rescued to nil + logged, so
    # a DB hiccup degrades to the API path, never masks it.
    def live_progress(nwo, sha, workflow_name = nil)
      rows = CiCheckJob.progress_rows(nwo, sha, workflow_name)
      return nil if rows.empty?

      CheckProgress.from_check_runs(rows, sha: sha, run_started_at: run_started_at_for(nwo, sha, workflow_name))
    rescue StandardError => e
      ErrorLog.capture!(e)
      nil
    end

    # When the CI run for this SHA BEGAN — `github_workflow_runs.run_started_at`, the
    # stamp the `workflow_run` webhook already ingests, newest run first. It is the
    # meter clock's ORIGIN: the run start beats the earliest job start, because a job
    # that queued behind a runner still belongs to a run that began earlier. nil when
    # no run row exists (the checks' own stamps then answer, and failing that the
    # meter simply shows no clock). Rescued, like every read on this path.
    def run_started_at_for(nwo, sha, workflow_name = nil)
      scope = GithubWorkflowRun.for_repo(nwo).where(head_sha: sha)
      scope = scope.where(workflow_name: workflow_name) if workflow_name.present?
      scope.order(Arel.sql(LATEST_RUN_ORDER)).limit(1).pick(:run_started_at)
    rescue StandardError => e
      ErrorLog.capture!(e)
      nil
    end

    # HTTP + fold, budgeted and fully rescued. Any failure is a blank bar, logged.
    def fetch_progress(nwo, sha)
      body = Timeout.timeout(REQUEST_BUDGET_SECONDS) do
        client.get("repos/#{nwo}/commits/#{sha}/check-runs", params: { per_page: 100 })
      end
      runs = body.is_a?(Hash) ? body["check_runs"] : body
      CheckProgress.from_check_runs(runs, sha: sha, run_started_at: run_started_at_for(nwo, sha))
    rescue StandardError => e
      ErrorLog.capture!(e)
      CheckProgress.blank(sha: sha)
    end

    def client
      @client ||= Github::Client.new
    end

    def eligible_task?(task)
      return false unless task.respond_to?(:devops_url)

      TASK_STAGES_WITH_CI.include?(task.stage.to_s) &&
        task.devops_url("pr").present? &&
        task_branch(task).present?
    end

    def task_branch(task)
      task.devops_field("branch").to_s.presence
    end

    # WHICH repo's CI this task's meter draws: the repo its PR is actually in —
    # Ci::ReviewGate.repos_for, the SAME derivation the review gate grades, so the
    # display and the gate can never disagree about a task's repo. Falls back to the
    # first declared repo (no PR yet, or an unparseable url), then the hub.
    #
    # IT USED TO BE `repositories.first`, which is not the PR's repo whenever a task
    # names something else first — a gem task names its CONSUMERS ([mcritchie-studio,
    # turf-monster]) behind ONE studio-engine PR — so the meter looked for the hub's
    # runs on a branch that only exists in the gem: blank, or another repo's CI if a
    # branch of that name happened to exist there.
    #
    # A GEM TASK'S CARD WAS BLANK until 2026-08-25, for a DIFFERENT collapse that
    # naming the right repo did not fix: the task path resolved its sha with the
    # default `CI` workflow name while a gem's runs are its own suite ("Engine CI"),
    # so the read matched nothing. #task_ci_target now resolves that name per repo.
    # Measured on studio-engine PR #195 (feat/polish-style-guide-modals): the sha
    # read via "CI" was nil and via "Engine CI" was 4b9fc19, carrying a full 3/3
    # fold. The harm was not the missing bar — it was that a BLANK meter and a RED
    # one are the same pixels, so a genuinely failing Consumer CI was diagnosed as
    # an unwired webhook. Ci::Ingestion.unwired was [] the whole time.
    #
    # ONE TRACK, AND IT IS THE PRIMARY PR's — a stated display LIMIT, not an
    # oversight. A task with PRs in two repos has two CI runs; this bar shows the one
    # its `pr_url` links to. Nothing is gated on it: Ci::ReviewGate folds EVERY repo,
    # so a red second repo still blocks the claim and the armed merge even though this
    # bar cannot draw it. Drawing both needs a second meter slot per card, because a
    # CheckProgress is ONE sha's fold and merging two repos into it would invent a sha
    # its run link then points nowhere with. #for_release already does per-repo tracks
    # if that is ever wanted here.
    def task_repo(task)
      gate_repo = (Ci::ReviewGate.repos_for(task).first if task.respond_to?(:release_pr_urls))
      gate_repo.presence || Array(task.devops_repositories).first.to_s.presence || HUB_REPO
    end

    # WHERE a task's PR CI lives: [nwo, branch, workflow, repo]. The WORKFLOW is the
    # part that was missing — resolved per repo through GithubWorkflowRun's single
    # decider, exactly as Ci::ReviewGate resolves it, so the meter and the gate can
    # no longer disagree about which runs are this task's. nil workflow keeps
    # #latest_ci_sha's documented "newest run of any workflow" contract for a gem
    # that declares no suite.
    def task_ci_target(task)
      repo = task_repo(task)
      [nwo_for(repo), task_branch(task), GithubWorkflowRun.ci_workflow_for(repo), repo]
    end

    # The task card's fold: the repo's own suite at JOB grain, plus one mark per
    # declared SIBLING suite lane at RUN grain.
    #
    # THE SIBLING LANES ARE THE POINT, and this is where the task card deliberately
    # DIVERGES from Ci::LadderRung#progress, which scopes its fold to the primary
    # workflow alone. The two answer different questions. The ladder rung asks "is
    # this gem's OWN suite green on its branch tip", so folding a failing downstream
    # Consumer CI into it would drag the gem's track red for something that is not
    # the gem's fault. A TASK card asks Ci::ReviewGate's question — "is this PR
    # merge-ready" — and the gate folds EVERY run on the head sha, so a red Consumer
    # CI genuinely blocks this task. Scoping the card to the primary here would draw
    # a green 3/3 meter on a task the gate holds red, which is worse than the blank
    # bar this change removes: blank reads as "no data", green reads as a lie.
    #
    # TWO GRAINS because the ingest records CiCheckJob rows only for
    # GithubWorkflowRun::CI_PROGRESS_WORKFLOWS (each repo's own suite), so a sibling
    # lane has no per-job rows to fold — only its workflow_run row. One mark for the
    # whole lane is the honest resolution available, and it is enough: the mark's
    # state is what turns the meter red.
    # AN UNFOLDED PRIMARY KEEPS ITS BLANK BAR — siblings decorate a suite fold, they
    # never stand in for one. GitHub delivers `workflow_run` at QUEUE time, so an
    # "Engine CI" RUN row (and therefore a resolved sha) exists before any of its
    # jobs do; #for_sha then refuses the workflow-blind API fallback for a gem and
    # hands back a BLANK base. Concatenating onto that would leave a green sibling as
    # the ONLY mark — :green drawn on a tree Ci::ReviewGate folds :pending, because
    # the gate votes the queued primary run this bar could not see. That is the same
    # green-reads-as-a-lie this fold exists to prevent, pointed the other way, so an
    # empty base short-circuits exactly like an empty sibling set.
    def task_progress(nwo, repo, sha, workflow)
      base = for_sha(nwo, sha, workflow)
      siblings = sibling_lane_checks(nwo, repo, sha, workflow)
      return base if siblings.empty? || base.checks.empty?

      CheckProgress.new(checks: base.checks + siblings, sha: sha, run_started_at: base.run_started_at)
    end

    # One Ci::CheckProgress::Check per DECLARED sibling suite lane on this head, or
    # [] when the repo declares none (every app repo). An ALLOW-LIST via
    # .suite_workflows_for, so an undeclared workflow — a nightly, a CodeQL scan, a
    # Pages build — never lands a mark on a task card. Newest run wins per lane,
    # mirroring Ci::ReviewGate#check_runs_payload. Rescued: a sibling read may never
    # break the card that would otherwise render.
    def sibling_lane_checks(nwo, repo, sha, workflow)
      names = GithubWorkflowRun.suite_workflows_for(repo).map(&:to_s).uniq - [workflow.to_s]
      return [] if names.empty?

      rows = GithubWorkflowRun.for_repo(nwo).for_sha(sha).where(workflow_name: names)
                              .order(Arel.sql(LATEST_RUN_ORDER)).to_a
                              .group_by { |run| run.workflow_name.to_s }
                              .map { |name, runs| sibling_lane_row(name, runs.first) }
      CheckProgress.from_check_runs(rows).checks
    rescue StandardError => e
      ErrorLog.capture!(e)
      []
    end

    # A workflow_run row shaped as the check row CheckProgress.from_check_runs folds.
    # `completed_at` only once the run is terminal, so an in-flight lane contributes
    # no false end-stamp to the meter's clock.
    def sibling_lane_row(name, run)
      { "name" => name, "status" => run.status.to_s, "conclusion" => run.conclusion.to_s,
        "started_at" => run.run_started_at, "completed_at" => (run.updated_at if run.terminal?) }
    end

    def nwo_for(repo)
      repo = repo.to_s.strip
      return "" if repo.empty?
      return repo if repo.include?("/") # already an owner/repo

      "#{DEFAULT_OWNER}/#{repo}"
    end

    # The bare repo slug from an owner/repo (the inverse of nwo_for) — so a
    # workflow_job's `repo` full name maps back to a release member slug.
    def repo_slug(nwo)
      nwo.to_s.strip.split("/").last.to_s
    end

    # The DISTINCT member repos of a release, producer-first (mirroring
    # ordered_members: gems before apps), one entry per repo whose code is in the
    # release. Empty for a release with no members or that cannot enumerate them.
    def member_repos(release)
      return [] unless release.respond_to?(:ordered_members)

      # EVERY repo each member names (Task#release_repos) — a member spanning two
      # repos has CI in both, and the singular read showed only its primary.
      release.ordered_members.flat_map(&:release_repos).uniq
    end

    # Where a repo's release-candidate CI lives: [nwo, branch, workflow_name]. App
    # repos → the `release` branch's `name: "CI"` run; gem repos → their own suite on
    # `main` (workflow may be nil for an unmapped gem, meaning "newest main run of any
    # workflow"). See GEM_CI_WORKFLOWS.
    def ci_target_for(repo)
      nwo = nwo_for(repo)
      return [nwo, GEM_CI_BRANCH, GEM_CI_WORKFLOWS[repo]] if Release::Repos.gem?(repo)

      [nwo, Release::BRANCH, GithubWorkflowRun::CI_WORKFLOW]
    end

    # Latest ingested CI-run SHA for one repo+branch, or nil. `workflow_name` scopes
    # to a single workflow (the app-repo default `"CI"`); pass nil to take the newest
    # run on the branch regardless of workflow (the unmapped-gem fallback).
    def latest_ci_sha(nwo, branch, workflow_name = GithubWorkflowRun::CI_WORKFLOW)
      return nil if nwo.to_s.empty? || branch.to_s.empty?

      scope = GithubWorkflowRun.for_repo(nwo).where(head_branch: branch)
      scope = scope.where(workflow_name: workflow_name) if workflow_name.present?
      scope.order(Arel.sql(LATEST_RUN_ORDER)).limit(1).pick(:head_sha)
    end

    # Sibling of latest_ci_sha: the html_url of the newest ingested CI run for one
    # repo+branch(+workflow), or nil. Same scope + ordering, so the URL points at the
    # EXACT run whose SHA latest_ci_sha resolves for that track's progress.
    def latest_ci_run_url(nwo, branch, workflow_name = GithubWorkflowRun::CI_WORKFLOW)
      return nil if nwo.to_s.empty? || branch.to_s.empty?

      scope = GithubWorkflowRun.for_repo(nwo).where(head_branch: branch)
      scope = scope.where(workflow_name: workflow_name) if workflow_name.present?
      scope.order(Arel.sql(LATEST_RUN_ORDER)).limit(1).pick(:html_url).presence
    end

    # Batched sibling of latest_ci_sha: one query for every [nwo, branch, workflow]
    # target. Keyed on the WORKFLOW too, because that is now per repo — the old
    # version pinned `workflow_name: CI_WORKFLOW` in the query itself, so a gem task
    # resolved no sha here for exactly the reason #task_ci_target documents.
    def latest_ci_shas(targets)
      targets = targets.map { |target| target.first(3) }
                       .reject { |nwo, branch, _workflow| nwo.to_s.empty? || branch.to_s.empty? }.uniq
      return {} if targets.empty?

      workflows = targets.map(&:last)
      scope = GithubWorkflowRun.where(repo: targets.map(&:first).uniq,
                                      head_branch: targets.map { |target| target[1] }.uniq)
      # Narrow in SQL only when EVERY target named a workflow. One unmapped gem
      # (workflow nil, meaning "newest run of any workflow") must not have the other
      # targets' names filter its rows away.
      scope = scope.where(workflow_name: workflows.uniq) if workflows.all?(&:present?)
      rows = scope.order(Arel.sql(LATEST_RUN_ORDER)).pluck(:repo, :head_branch, :workflow_name, :head_sha)

      rows.each_with_object({}) do |(repo, branch, workflow, sha), memo|
        memo[[repo, branch, workflow]] ||= sha # first seen == newest (ordered above)
        memo[[repo, branch, nil]] ||= sha      # the unmapped-gem key: any workflow
      end
    end

    # --- Fixture seam (demo + tests, no network) -------------------------------
    # CI_PROGRESS_FIXTURES is a JSON map { sha => runs-array | {passed,failed,pending} }
    # so a local demo and the test suite render real bars without hitting GitHub —
    # the same shape the check-runs fold consumes.
    def env_fixtures
      # The fixture seam is a demo/test affordance only — never let a stray
      # CI_PROGRESS_FIXTURES on a production dyno paint fake bars over real CI.
      return {} if Rails.env.production?

      raw = ENV["CI_PROGRESS_FIXTURES"].to_s.strip
      return {} if raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    def fixture?(sha)
      @fixtures.is_a?(Hash) && @fixtures.key?(sha.to_s)
    end

    def fixture_progress(sha)
      value = @fixtures[sha.to_s]
      case value
      when Array
        CheckProgress.from_check_runs(value, sha: sha)
      when Hash
        CheckProgress.new(
          passed: value["passed"] || value[:passed],
          failed: value["failed"] || value[:failed],
          pending: value["pending"] || value[:pending],
          sha: sha
        )
      else
        CheckProgress.blank(sha: sha)
      end
    end
  end
end
