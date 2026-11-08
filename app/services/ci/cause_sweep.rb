require Rails.root.join("bin/lib/ci_cause_detector").to_s

module Ci
  # Reads a repo's CI history and enqueues CiCauseCardJob for every same-SHA red that
  # a later run proved green (CiCauseDetector.flips). Run by `bin/rails
  # ci:causes:sweep`; the live path is GithubWorkflowRunIngestJob. Task: deterministic-ci.
  #
  # A run row carries only its LATEST attempt, so a re-run that passed hides its red:
  # every run with run_attempt > 1 also has its earlier attempts read.
  class CauseSweep
    MAX_PAGES = 10

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(repo:, days: 14, dry_run: false, client: Github::Client.new)
      @repo = repo
      @since = days.to_i.days.ago.to_date
      @dry_run = dry_run
      @client = client
    end

    def call
      flips = CiCauseDetector.flips(rows)
      flips.each { |f| enqueue(f) } unless @dry_run
      flips
    end

    private

    def rows
      runs.flat_map do |run|
        latest = row(run, run["run_attempt"], run["conclusion"])
        earlier = (1...run["run_attempt"].to_i).map do |n|
          attempt = @client.get("/repos/#{@repo}/actions/runs/#{run['id']}/attempts/#{n}")
          row(run, n, attempt["conclusion"])
        end
        [latest, *earlier]
      end
    end

    def runs
      out = []
      (1..MAX_PAGES).each do |page|
        body = @client.get("/repos/#{@repo}/actions/runs",
                           params: { status: "completed", created: ">=#{@since.iso8601}", per_page: 100, page: page })
        batch = Array(body["workflow_runs"])
        out.concat(batch.reject { |r| r["event"] == "schedule" })
        break if batch.size < 100
      end
      out
    end

    def row(run, attempt, conclusion)
      { run_id: run["id"], attempt: attempt || 1, conclusion: conclusion, sha: run["head_sha"], workflow: run["name"] }
    end

    def enqueue(flip)
      CiCauseCardJob.perform_later(@repo, flip[:red][:run_id], flip[:red][:attempt], flip[:green][:run_id], flip[:green][:attempt])
    end
  end
end
