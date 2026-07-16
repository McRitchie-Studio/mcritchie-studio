# frozen_string_literal: true

require "timeout"

module Ci
  # Reads GitHub CI check progress for a commit and folds it into a
  # Ci::CheckProgress (passed / total / state) for the board's progress bars.
  #
  # DATA SOURCE (deliberate, "start simple"): a render-time, SHA-addressed
  # check-runs read via the in-app Github::Client, wrapped in Rails.cache so the
  # board makes at most one API call per SHA per TTL window regardless of how many
  # viewers or cards ask. The SHA itself is resolved for FREE from the already-
  # ingested `GithubWorkflowRun` webhook rows (a task's branch tip; the `release`
  # branch tip) — so we hit GitHub ONLY for the per-check counts the webhook does
  # not store, and only once a CI run actually exists.
  #
  # This touches nothing the release conductor / sweep own: it READS GitHub CI, it
  # never emits progress from the pipeline. A live check_run -> Turbo Stream push
  # is a clean future upgrade (see components/_ci_progress_bar.html.erb); we chose
  # cached-on-render over extending the webhook because it needs no GitHub App
  # config change and no new table — cheaper to ship, honest about the trade.
  #
  # DEGRADES TO BLANK, ALWAYS: no PR, no CI run, no token, an unreadable payload,
  # a slow/hung API, or any error -> Ci::CheckProgress.blank (the bar renders
  # nothing). Every rescue lands in ErrorLog (backend discipline).
  class ProgressReader
    # The org every managed repo lives under (amcritchie/<repo>), overridable for a
    # fork/test. Matches Github::PendingDeploymentScanner::DEFAULT_REPO's owner.
    DEFAULT_OWNER = ENV.fetch("GITHUB_REPO_OWNER", "amcritchie").freeze

    # The repo whose `release` branch tip carries the G3 candidate suite CI run.
    HUB_REPO = "mcritchie-studio"

    # Only a submitted-onward task shows a CI bar — before the PR there is no run.
    TASK_STAGES_WITH_CI = %w[submitted reviewed assembled].freeze

    # Newest-run ordering, mirroring GithubWorkflowRun.latest_per_workflow.
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

      nwo = nwo_for(task_repo(task))
      sha = latest_ci_sha(nwo, task_branch(task))
      return CheckProgress.blank unless sha

      for_sha(nwo, sha)
    end

    # Batched: { slug => Ci::CheckProgress } for every eligible task, resolving all
    # branch tips in ONE query. Non-eligible tasks are simply absent from the map.
    def progress_by_slug(tasks)
      eligible = Array(tasks).select { |task| eligible_task?(task) }
      return {} if eligible.empty?

      shas = latest_ci_shas(eligible.map { |task| [nwo_for(task_repo(task)), task_branch(task)] })
      eligible.each_with_object({}) do |task, memo|
        sha = shas[[nwo_for(task_repo(task)), task_branch(task)]]
        next unless sha

        memo[task.slug] = for_sha(nwo_for(task_repo(task)), sha)
      end
    end

    # The G3 candidate suite: the CI run on the release-branch tip of the hub repo,
    # shown while the release is assembling/assembled. Blank otherwise.
    def for_release(release)
      return CheckProgress.blank unless release.respond_to?(:active?) && release.active?

      nwo = nwo_for(HUB_REPO)
      sha = latest_ci_sha(nwo, Release::BRANCH)
      return CheckProgress.blank unless sha

      for_sha(nwo, sha)
    end

    # The core read: SHA -> Ci::CheckProgress, cached + budgeted + rescued.
    def for_sha(nwo, sha)
      nwo = nwo.to_s
      sha = sha.to_s
      return CheckProgress.blank if nwo.empty? || sha.empty?
      return fixture_progress(sha) if fixture?(sha)

      cache_key = "ci:progress:#{nwo}:#{sha}"
      cached = @cache.read(cache_key)
      return cached if cached.is_a?(CheckProgress)

      progress = fetch_progress(nwo, sha)
      @cache.write(cache_key, progress, expires_in: progress.pending? ? LIVE_TTL : TERMINAL_TTL)
      progress
    end

    private

    # HTTP + fold, budgeted and fully rescued. Any failure is a blank bar, logged.
    def fetch_progress(nwo, sha)
      body = Timeout.timeout(REQUEST_BUDGET_SECONDS) do
        client.get("repos/#{nwo}/commits/#{sha}/check-runs", params: { per_page: 100 })
      end
      runs = body.is_a?(Hash) ? body["check_runs"] : body
      CheckProgress.from_check_runs(runs, sha: sha)
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

    def task_repo(task)
      Array(task.devops_repositories).first.to_s.presence || HUB_REPO
    end

    def nwo_for(repo)
      repo = repo.to_s.strip
      return "" if repo.empty?
      return repo if repo.include?("/") # already an owner/repo

      "#{DEFAULT_OWNER}/#{repo}"
    end

    # Latest ingested CI-run SHA for one repo+branch, or nil.
    def latest_ci_sha(nwo, branch)
      return nil if nwo.to_s.empty? || branch.to_s.empty?

      GithubWorkflowRun
        .for_repo(nwo)
        .where(head_branch: branch, workflow_name: "CI")
        .order(Arel.sql(LATEST_RUN_ORDER))
        .limit(1)
        .pick(:head_sha)
    end

    # Batched sibling of latest_ci_sha: one query for every [nwo, branch] pair.
    def latest_ci_shas(pairs)
      pairs = pairs.reject { |nwo, branch| nwo.to_s.empty? || branch.to_s.empty? }.uniq
      return {} if pairs.empty?

      rows = GithubWorkflowRun
             .where(repo: pairs.map(&:first).uniq, head_branch: pairs.map(&:last).uniq, workflow_name: "CI")
             .order(Arel.sql(LATEST_RUN_ORDER))
             .pluck(:repo, :head_branch, :head_sha)

      rows.each_with_object({}) do |(repo, branch, sha), memo|
        memo[[repo, branch]] ||= sha # first seen == newest (ordered above)
      end
    end

    # --- Fixture seam (demo + tests, no network) -------------------------------
    # CI_PROGRESS_FIXTURES is a JSON map { sha => runs-array | {passed,failed,pending} }
    # so a local demo and the test suite render real bars without hitting GitHub —
    # the same shape the check-runs fold consumes.
    def env_fixtures
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
