require "test_helper"

# [unit] Github::DeploymentApprover — reads the run's pending deployments to find
# the environment id(s) it is blocked on, then approves them with state=approved.
class Github::DeploymentApproverTest < ActiveSupport::TestCase
  # A recording double for Github::Client — captures the GET/POST calls and
  # returns canned pending-deployment payloads.
  class FakeClient
    attr_reader :posts

    def initialize(pending:)
      @pending = pending
      @posts = []
    end

    def get(path)
      @get_path = path
      @pending
    end

    def post(path, body:)
      @posts << { path: path, body: body }
      { "state" => "approved" }
    end

    attr_reader :get_path
  end

  def pending_run(repo: "mcritchie/mcritchie-studio", run_id: 555)
    GithubWorkflowRun.create!(repo: repo, run_id: run_id, status: "in_progress",
                              workflow_name: "Production Deploy", pending_environment: "production")
  end

  test "[unit] approves every pending environment id via state=approved" do
    client = FakeClient.new(pending: [
      { "environment" => { "id" => 42, "name" => "production" } },
      { "environment" => { "id" => 43, "name" => "production-extra" } }
    ])

    Github::DeploymentApprover.new(pending_run, client: client).approve!

    assert_equal 1, client.posts.size
    post = client.posts.first
    assert_equal "/repos/mcritchie/mcritchie-studio/actions/runs/555/pending_deployments", post[:path]
    assert_equal [42, 43], post[:body][:environment_ids]
    assert_equal "approved", post[:body][:state]
    assert post[:body][:comment].present?
  end

  test "[unit] reads pending deployments from the run-scoped endpoint" do
    client = FakeClient.new(pending: [{ "environment" => { "id" => 7 } }])
    Github::DeploymentApprover.new(pending_run(run_id: 999), client: client).approve!
    assert_equal "/repos/mcritchie/mcritchie-studio/actions/runs/999/pending_deployments", client.get_path
  end

  test "[unit] raises NoPendingDeployment when GitHub reports nothing waiting" do
    client = FakeClient.new(pending: [])
    assert_raises(Github::DeploymentApprover::NoPendingDeployment) do
      Github::DeploymentApprover.new(pending_run, client: client).approve!
    end
    assert_empty client.posts
  end

  test "[unit] raises when the run carries no owner/repo" do
    client = FakeClient.new(pending: [{ "environment" => { "id" => 1 } }])
    bare = GithubWorkflowRun.create!(repo: "no-slash", run_id: 12, status: "in_progress",
                                     pending_environment: "production")
    assert_raises(Github::DeploymentApprover::Error) do
      Github::DeploymentApprover.new(bare, client: client).approve!
    end
  end

  test "[unit] dedupes repeated environment ids" do
    client = FakeClient.new(pending: [
      { "environment" => { "id" => 5 } },
      { "environment" => { "id" => 5 } }
    ])
    Github::DeploymentApprover.new(pending_run, client: client).approve!
    assert_equal [5], client.posts.first[:body][:environment_ids]
  end
end
