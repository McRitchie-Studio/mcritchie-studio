# frozen_string_literal: true

module Github
  # Approves a workflow run that is waiting at a protected-environment gate, from
  # the McRitchie Studio board. Reads the run's pending deployments to discover the
  # environment id(s) it is blocked on, then approves them via GitHub's
  #   POST /repos/{owner}/{repo}/actions/runs/{run_id}/pending_deployments
  # with `state: approved`. Reading the env ids live (rather than trusting a stored
  # id) keeps the approve robust to a run gated on more than one environment.
  #
  # Authenticated with the agent PAT — `ENV["GITHUB_TOKEN"]` (1Password
  # agent.github field personal-access-token; the same token Github::Client
  # defaults to). The controller admin-gates the trigger; this class assumes it is
  # already authorized.
  class DeploymentApprover
    class Error < StandardError; end
    class NoPendingDeployment < Error; end

    APPROVAL_COMMENT = "Approved from the McRitchie Studio deployments board"

    def initialize(run, client: nil)
      @run = run
      @client = client || Github::Client.new(token: self.class.token)
    end

    # Discover + approve every environment the run is blocked on. Returns the
    # GitHub response (the approved deployments). Raises NoPendingDeployment when
    # GitHub reports nothing waiting (already approved, or the run advanced).
    def approve!
      owner, repo = split_repo
      env_ids = pending_environment_ids(owner, repo)
      raise NoPendingDeployment, "no pending deployments for run #{@run.run_id}" if env_ids.empty?

      @client.post(
        "/repos/#{owner}/#{repo}/actions/runs/#{@run.run_id}/pending_deployments",
        body: { environment_ids: env_ids, state: "approved", comment: APPROVAL_COMMENT }
      )
    end

    def self.token
      ENV["GITHUB_TOKEN"].presence || ENV["GITHUB_PAT"].presence
    end

    private

    def split_repo
      owner, repo = @run.repo.to_s.split("/", 2)
      raise Error, "run #{@run.run_id} has no owner/repo (repo=#{@run.repo.inspect})" if owner.blank? || repo.blank?

      [owner, repo]
    end

    # The environment ids this run is currently waiting on. GitHub returns an array
    # of pending-deployment objects, each nesting `environment: { id, name }`.
    def pending_environment_ids(owner, repo)
      pending = @client.get("/repos/#{owner}/#{repo}/actions/runs/#{@run.run_id}/pending_deployments")
      Array(pending).filter_map { |dep| dep.dig("environment", "id") }.uniq
    end
  end
end
