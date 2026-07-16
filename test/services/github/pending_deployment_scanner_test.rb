require "test_helper"

# [unit] Github::PendingDeploymentScanner — the production trigger. Lists runs
# waiting on an environment gate and replays each through the ingest job, so the
# pending stamp + Discord ping fire even though GitHub won't deliver
# `deployment_review` to our PAT webhook. Also clears runs no longer waiting.
class Github::PendingDeploymentScannerTest < ActiveSupport::TestCase
  REPO = "amcritchie/mcritchie-studio"

  # Routes get() by path: the runs list vs a run's pending_deployments.
  class FakeClient
    attr_reader :calls

    def initialize(waiting: [], pending_by_run: {})
      @waiting = waiting
      @pending_by_run = pending_by_run
      @calls = []
    end

    def get(path, params: {}, headers: {})
      @calls << path
      if path.end_with?("/actions/runs")
        { "workflow_runs" => @waiting }
      elsif (m = path.match(%r{/actions/runs/(\d+)/pending_deployments}))
        @pending_by_run.fetch(m[1].to_i, [])
      else
        {}
      end
    end
  end

  def run_hash(id, name: "Production Deploy")
    { "id" => id, "name" => name, "status" => "waiting", "head_sha" => "abc123def456",
      "head_branch" => "release", "html_url" => "https://github.com/#{REPO}/actions/runs/#{id}",
      "run_started_at" => "2026-07-15T08:00:00Z" }
  end

  def scan(client)
    pings = []
    Devops::DeployApprovalNotifier.stub(:notify_pending, ->(run) { pings << run.run_id; true }) do
      seen = Github::PendingDeploymentScanner.new(repo: REPO, client: client).scan!
      [seen, pings]
    end
  end

  test "[unit] flags each waiting run with its environment and pings once" do
    client = FakeClient.new(
      waiting: [run_hash(101), run_hash(102)],
      pending_by_run: { 101 => [{ "environment" => { "name" => "production" } }],
                        102 => [{ "environment" => { "name" => "production" } }] }
    )

    seen, pings = scan(client)

    assert_equal [101, 102], seen.sort
    r101 = GithubWorkflowRun.find_by(run_id: 101)
    assert_equal "production", r101.pending_environment
    assert_equal "Production Deploy", r101.workflow_name
    assert_equal REPO, r101.repo
    assert_equal [101, 102], pings.sort
  end

  test "[unit] a second scan does not re-ping an already-pending run" do
    client = FakeClient.new(
      waiting: [run_hash(201)],
      pending_by_run: { 201 => [{ "environment" => { "name" => "production" } }] }
    )
    _seen, first = scan(client)
    _seen2, second = scan(client)

    assert_equal [201], first
    assert_empty second, "already-pending run must not re-ping on the next poll"
  end

  test "[unit] a waiting run with no pending environment review is skipped" do
    client = FakeClient.new(waiting: [run_hash(301)], pending_by_run: { 301 => [] })
    seen, pings = scan(client)

    assert_empty seen
    assert_nil GithubWorkflowRun.find_by(run_id: 301)
    assert_empty pings
  end

  test "[unit] clears a run that is no longer waiting" do
    GithubWorkflowRun.create!(repo: REPO, run_id: 401, status: "in_progress",
                              workflow_name: "Production Deploy", pending_environment: "production",
                              pending_since: 1.hour.ago)
    # Nothing waiting on GitHub now → the stale local gate must clear.
    client = FakeClient.new(waiting: [], pending_by_run: {})
    scan(client)

    assert_not GithubWorkflowRun.find_by(run_id: 401).pending_approval?
  end

  test "[unit] keeps a still-waiting run flagged while clearing a resolved one" do
    GithubWorkflowRun.create!(repo: REPO, run_id: 501, status: "in_progress",
                              workflow_name: "Production Deploy", pending_environment: "production",
                              pending_since: 1.hour.ago)
    client = FakeClient.new(
      waiting: [run_hash(502)],
      pending_by_run: { 502 => [{ "environment" => { "name" => "production" } }] }
    )
    scan(client)

    assert_not GithubWorkflowRun.find_by(run_id: 501).pending_approval?, "resolved run clears"
    assert GithubWorkflowRun.find_by(run_id: 502).pending_approval?, "newly-waiting run flags"
  end

  test "[unit] an unparseable repo is a safe no-op" do
    assert_equal [], Github::PendingDeploymentScanner.new(repo: "no-slash", client: FakeClient.new).scan!
  end

  test "[unit] an API error is captured to ErrorLog and never raised" do
    boom = Object.new
    def boom.get(*) = raise(Github::Client::HttpError, "GitHub down")

    assert_difference -> { ErrorLog.count }, 1 do
      assert_nothing_raised do
        assert_equal [], Github::PendingDeploymentScanner.new(repo: REPO, client: boom).scan!
      end
    end
  end
end
