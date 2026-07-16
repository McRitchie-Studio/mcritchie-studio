# frozen_string_literal: true

module Github
  # The PRODUCTION trigger for the prod-deploy approval gate. GitHub refuses to
  # deliver `deployment_review` to a repo webhook created with a PAT (422: events
  # not allowed), so the webhook path (GithubWebhooksController) only ever carries
  # `workflow_run`. This scanner supplies the missing signal by READING it: it lists
  # runs currently `waiting` on a protected-environment gate and replays each as the
  # same `deployment_review` event the ingest job already handles — so the panel,
  # the Approve button, and the Discord nudge all light up with ZERO extra logic.
  #
  # Runs on a recurring schedule (config/recurring.yml, production only). Reuses
  # GithubWorkflowRunIngestJob so the pending stamp, the ping-once transition, and
  # the idempotent upsert stay in ONE place. Fail-safe: unconfigured is a no-op, and
  # any error is logged to ErrorLog, never raised (a recurring job must not crash).
  class PendingDeploymentScanner
    DEFAULT_REPO = "amcritchie/mcritchie-studio"
    RUN_FIELDS = %w[id name status head_sha head_branch html_url run_started_at].freeze

    def self.scan!(**kwargs)
      new(**kwargs).scan!
    end

    def initialize(repo: nil, client: nil)
      @repo = (repo || ENV["GITHUB_DEPLOY_APPROVAL_REPO"].presence || DEFAULT_REPO).to_s
      @client = client
    end

    def scan!
      owner, name = @repo.split("/", 2)
      return log_skip("repo #{@repo.inspect} is not owner/repo") if owner.blank? || name.blank?
      return log_skip("no GitHub token configured") if @client.nil? && token.blank?

      seen_run_ids = flag_waiting(owner, name)
      clear_resolved(seen_run_ids)
      seen_run_ids
    rescue StandardError => e
      ErrorLog.capture!(e)
      []
    end

    private

    # Stamp every run GitHub reports as waiting on an environment gate. Returns the
    # run_ids seen so the caller can clear anything no longer waiting.
    def flag_waiting(owner, name)
      waiting_runs(owner, name).filter_map do |run|
        run_id = run["id"]
        next if run_id.blank?

        environment = first_pending_environment(owner, name, run_id)
        next if environment.blank? # waiting on something that is not an env review

        replay_review("requested", run.slice(*RUN_FIELDS), environment)
        run_id
      end
    end

    # Any run we have flagged pending that GitHub no longer lists as waiting was
    # approved/rejected/timed-out out of band — replay an `approved` review to clear
    # the local gate (the webhook that would have told us never arrives).
    def clear_resolved(seen_run_ids)
      GithubWorkflowRun.pending_approval.where.not(run_id: seen_run_ids).find_each do |stale|
        replay_review("approved", { "id" => stale.run_id }, nil, repo: stale.repo)
      end
    end

    # Replay a pending-deployments read as the deployment_review event the ingest
    # job handles — the one place the pending stamp + ping-once transition live.
    def replay_review(action, run_fields, environment, repo: @repo)
      payload = {
        "action" => action,
        "workflow_run" => run_fields,
        "repository" => { "full_name" => repo }
      }
      payload["environment"] = environment if environment.present?
      GithubWorkflowRunIngestJob.perform_now("deployment_review", payload)
    end

    def waiting_runs(owner, name)
      body = client.get("/repos/#{owner}/#{name}/actions/runs", params: { status: "waiting", per_page: 50 })
      Array(body.is_a?(Hash) ? body["workflow_runs"] : body)
    end

    def first_pending_environment(owner, name, run_id)
      pending = client.get("/repos/#{owner}/#{name}/actions/runs/#{run_id}/pending_deployments")
      Array(pending).filter_map { |dep| dep.dig("environment", "name") }.first
    end

    def client
      @client ||= Github::Client.new(token: token)
    end

    def token
      @token ||= ENV["GITHUB_TOKEN"].presence || ENV["GITHUB_PAT"].presence
    end

    def log_skip(reason)
      Rails.logger.info("[PendingDeploymentScanner] skipped: #{reason}")
      []
    end
  end
end
