# frozen_string_literal: true

require "test_helper"

# THE WHOLE HOP, end to end: a reviewer arms a merge and disappears, GitHub
# delivers a CI webhook, and the recorded decision finishes executing with no
# agent awake. This is the failure the feature exists for — seven times in one
# night a verdict was right and only its execution was lost.
class ReviewAutopilotFlowTest < ActionDispatch::IntegrationTest
  SLUG = "autopilot-flow-subject"
  REPO = "McRitchie-Studio/mcritchie-studio"
  BRANCH = "feat/autopilot-flow-subject"
  PINNED = "1234567890abcdef1234567890abcdef12345678"

  def setup
    @task = Task.create!(
      title: "Autopilot Flow Subject", slug: SLUG, stage: "submitted",
      metadata: { "devops" => {
        "repositories" => ["mcritchie-studio"], "branch" => BRANCH,
        "pr_url" => "https://github.com/#{REPO}/pull/909"
      } }
    )
    @secret = "webhook-test-secret"
  end

  def record_verdict(outcome: "merge-ready")
    Activity.create!(task_slug: SLUG, agent_slug: "carl", activity_type: "comment",
                     description: "Scout report: #{outcome}",
                     metadata: { "kind" => "scout_report", "outcome" => outcome })
  end

  def arm!(head_sha: PINNED)
    record_verdict
    ReviewPendingAction.arm!(task: @task.reload, repo: REPO, pr_number: 909, head_sha: head_sha,
                             authorized_by: "carl")
  end

  # A real signed delivery through the real receiver — the trigger has to survive
  # the whole path (HMAC → controller → ingest job → trigger), not just the last hop.
  def deliver_workflow_run(sha:, conclusion:, status: "completed", run_id: 555_001)
    payload = {
      "workflow_run" => {
        "id" => run_id, "name" => "CI", "status" => status, "conclusion" => conclusion,
        "head_sha" => sha, "head_branch" => BRANCH, "run_attempt" => 1,
        "run_started_at" => Time.current.iso8601, "html_url" => "https://github.com/run"
      },
      "repository" => { "full_name" => REPO }
    }.to_json

    signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)
    ENV.stub(:[], ->(key) { key == "GITHUB_WEBHOOK_SECRET" ? @secret : ENV.fetch(key, nil) }) do
      post "/api/v1/github/webhook", params: payload,
           headers: { "X-GitHub-Event" => "workflow_run", "X-Hub-Signature-256" => signature,
                      "CONTENT_TYPE" => "application/json" }
    end
    assert_response :ok
  end

  test "a GREEN CI delivery on the pinned tree enqueues the armed merge" do
    action = arm!

    perform_enqueued_jobs(only: GithubWorkflowRunIngestJob) do
      assert_enqueued_with(job: ReviewPendingActionExecutionJob, args: [action.id]) do
        deliver_workflow_run(sha: PINNED, conclusion: "success")
      end
    end
  end

  # A red lane authorises nothing — but note WHERE that is decided. The ingest
  # job triggers on ANY conclusion and never judges it; Ci::ReviewGate is the one
  # place that decides what green means. Duplicating that judgement in the ingest
  # ("only fire on success") would be a second, subtly different notion of green
  # free to drift from the gate that actually authorises merges. So the assertion
  # here is the one that matters: a red delivery reaches the executor and the
  # executor refuses — proven by a GitHub double that fails the test if touched.
  test "a RED CI delivery ingests, reaches the executor, and never merges" do
    action = arm!

    untouchable_github do
      perform_enqueued_jobs do
        deliver_workflow_run(sha: PINNED, conclusion: "failure")
      end
    end

    assert_equal "failure", GithubWorkflowRun.find_by(run_id: 555_001).conclusion
    assert_equal ReviewPendingAction::PENDING, action.reload.state
    @task.reload
    assert_equal "submitted", @task.stage
    assert_nil @task.merged
  end

  test "a still-running delivery enqueues nothing — only a CONCLUSION can arm anything" do
    arm!

    perform_enqueued_jobs(only: GithubWorkflowRunIngestJob) do
      assert_no_enqueued_jobs(only: ReviewPendingActionExecutionJob) do
        deliver_workflow_run(sha: PINNED, conclusion: nil, status: "in_progress")
      end
    end
  end

  test "a green delivery for a DIFFERENT tree never touches the pinned action" do
    arm!

    perform_enqueued_jobs(only: GithubWorkflowRunIngestJob) do
      assert_no_enqueued_jobs(only: ReviewPendingActionExecutionJob) do
        deliver_workflow_run(sha: "9" * 40, conclusion: "success")
      end
    end
  end

  # THE POINT OF THE WHOLE FEATURE, asserted as one hop: nobody is awake, the
  # webhook lands, and the recorded verdict finishes executing on its own.
  test "the recorded verdict executes with no agent awake" do
    action = arm!
    stub_github(sha: PINNED) do
      perform_enqueued_jobs do
        deliver_workflow_run(sha: PINNED, conclusion: "success")
      end
    end

    assert_equal ReviewPendingAction::EXECUTED, action.reload.state
    @task.reload
    assert_equal "accepted", @task.merged
    assert_equal "reviewed", @task.stage
  end

  test "the same hop refuses when the head moved under the pin" do
    action = arm!
    stub_github(sha: "e" * 40) do
      perform_enqueued_jobs do
        deliver_workflow_run(sha: PINNED, conclusion: "success")
      end
    end

    assert_equal ReviewPendingAction::REFUSED, action.reload.state
    assert_match(/head moved/, action.outcome_reason)
    @task.reload
    assert_equal "submitted", @task.stage
    assert_nil @task.merged
  end

  # ── the arm endpoint ────────────────────────────────────────────────────────

  test "the API refuses to arm without a recorded merge-ready verdict" do
    post "/api/v1/tasks/#{SLUG}/review_pending_action",
         params: { head_sha: PINNED }, headers: auth_headers
    assert_response :unprocessable_entity
    assert_match(/no recorded merge-ready scout report/, JSON.parse(response.body)["error"])
    assert_equal 0, ReviewPendingAction.count
  end

  test "the API refuses to arm without a pinned head sha" do
    record_verdict
    post "/api/v1/tasks/#{SLUG}/review_pending_action", params: {}, headers: auth_headers
    assert_response :unprocessable_entity
    assert_match(/head_sha is required/, JSON.parse(response.body)["error"])
  end

  test "the API arms on a recorded verdict and starts the retry chain" do
    record_verdict

    assert_enqueued_jobs 1, only: ReviewPendingActionExecutionJob do
      post "/api/v1/tasks/#{SLUG}/review_pending_action",
           params: { head_sha: PINNED, agent: "carl" }, headers: auth_headers
    end
    assert_response :created

    body = JSON.parse(response.body)["data"]
    assert_equal PINNED, body["head_sha"]
    assert_equal 909, body["pr_number"], "the PR number comes off the task's recorded PR url"
    assert_equal "pending", body["state"]
    assert_equal "merge-ready", body["verdict"]
  end

  test "disarming withdraws the standing order" do
    action = arm!
    delete "/api/v1/tasks/#{SLUG}/review_pending_action",
           params: { reason: "changed my mind" }, headers: auth_headers
    assert_response :ok
    assert_equal ReviewPendingAction::DISARMED, action.reload.state
    assert_equal "changed my mind", action.outcome_reason
  end

  private

  # A merging GitHub, injected at the client seam the executor resolves lazily.
  def stub_github(sha:, &block)
    fake = Class.new do
      define_method(:initialize) { |pr_sha| @pr_sha = pr_sha }
      define_method(:get) do |_path|
        { "state" => "open", "merged" => false, "mergeable" => true, "mergeable_state" => "clean",
          "head" => { "sha" => @pr_sha }, "base" => { "ref" => "accepted" } }
      end
      define_method(:put_response) do |_path, body: nil|
        Github::Client::Response.new(url: "u", status: 200, headers: {},
                                     body: { "sha" => "merged00" }, raw_body: "{}")
      end
    end.new(sha)

    Github::Client.stub(:new, fake, &block)
  end

  # A GitHub that fails the test if it is touched at all. The strongest way to
  # assert "this never reached GitHub": not a count of calls, but a client that
  # cannot be called.
  def untouchable_github(&block)
    test_case = self
    forbidden = Class.new do
      define_method(:get) { |*| test_case.flunk("the executor read GitHub for a lane that is not green") }
      define_method(:put_response) { |*, **| test_case.flunk("the executor tried to MERGE a lane that is not green") }
    end.new

    Github::Client.stub(:new, forbidden, &block)
  end

  def auth_headers
    { "Authorization" => "Bearer #{api_token}" }
  end

  def api_token
    @api_token ||= begin
      post "/api/v1/auth", params: { secret: ENV.fetch("AGENT_API_SECRET", "test-agent-secret") }
      JSON.parse(response.body).fetch("token")
    end
  end
end
