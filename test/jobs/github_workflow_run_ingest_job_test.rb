require "test_helper"

# [unit] GithubWorkflowRunIngestJob — the idempotent, monotonic upsert behind the
# webhook receiver. GitHub delivers AT-LEAST-ONCE and OUT OF ORDER, so these
# tests pin: no duplicates on re-delivery, status only ever advances, and a
# completed run's conclusion survives a late non-terminal re-delivery.
class GithubWorkflowRunIngestJobTest < ActiveJob::TestCase
  RUN_ID = 987_654_321

  # A realistic workflow_run event, parameterized on the lifecycle status so the
  # queued → in_progress → completed shapes are all exercised.
  def event(status:, conclusion: nil, run_id: RUN_ID, **overrides)
    {
      "action" => (status == "completed" ? "completed" : "requested"),
      "workflow_run" => {
        "id" => run_id,
        "name" => "CI",
        "status" => status,
        "conclusion" => conclusion,
        "html_url" => "https://github.com/mcritchie/mcritchie-studio/actions/runs/#{run_id}",
        "head_sha" => "9f2c1b7ad4e5c60f1e2d3a4b5c6d7e8f90123456",
        "head_branch" => "feat/webhook-push-not-poll",
        "run_started_at" => "2026-07-15T12:00:00Z"
      }.merge(overrides),
      "repository" => { "full_name" => "mcritchie/mcritchie-studio" }
    }
  end

  def ingest(status:, **kwargs)
    GithubWorkflowRunIngestJob.perform_now("workflow_run", event(status: status, **kwargs))
  end

  test "[unit] first delivery creates the run row with the mapped fields" do
    assert_difference "GithubWorkflowRun.count", 1 do
      ingest(status: "queued")
    end

    run = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "mcritchie/mcritchie-studio", run.repo
    assert_equal "CI", run.workflow_name
    assert_equal "queued", run.status
    assert_nil run.conclusion
    assert_equal "9f2c1b7ad4e5c60f1e2d3a4b5c6d7e8f90123456", run.head_sha
    assert_equal "feat/webhook-push-not-poll", run.head_branch
    assert_not_nil run.run_started_at
  end

  test "[unit] re-delivery of the same event is idempotent — no duplicate row" do
    2.times { ingest(status: "in_progress") }
    assert_equal 1, GithubWorkflowRun.where(run_id: RUN_ID).count
    assert_equal "in_progress", GithubWorkflowRun.find_by(run_id: RUN_ID).status
  end

  test "[unit] status advances queued -> in_progress -> completed" do
    ingest(status: "queued")
    ingest(status: "in_progress")
    ingest(status: "completed", conclusion: "success")

    run = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "completed", run.status
    assert_equal "success", run.conclusion
  end

  test "[unit] a late in_progress re-delivery never regresses a completed run" do
    ingest(status: "completed", conclusion: "success")
    ingest(status: "in_progress", conclusion: nil)

    run = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "completed", run.status, "monotonic: must not regress to in_progress"
    assert_equal "success", run.conclusion, "conclusion is first-write-wins; must survive"
  end

  test "[unit] out-of-order delivery (completed arrives first) ends completed" do
    ingest(status: "completed", conclusion: "failure")
    ingest(status: "queued")
    ingest(status: "in_progress")

    run = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "completed", run.status
    assert_equal "failure", run.conclusion
  end

  test "[unit] a re-delivered completed event does not overwrite the conclusion" do
    ingest(status: "completed", conclusion: "success")
    # An impossible-but-possible re-delivery carrying a different conclusion.
    ingest(status: "completed", conclusion: "failure")

    assert_equal "success", GithubWorkflowRun.find_by(run_id: RUN_ID).conclusion
  end

  test "[unit] non-workflow_run events are ignored gracefully" do
    assert_no_difference "GithubWorkflowRun.count" do
      GithubWorkflowRunIngestJob.perform_now("workflow_job", event(status: "queued"))
    end
  end

  test "[unit] a payload missing workflow_run.id is skipped without a row" do
    payload = event(status: "queued")
    payload["workflow_run"]["id"] = nil

    assert_no_difference "GithubWorkflowRun.count" do
      GithubWorkflowRunIngestJob.perform_now("workflow_run", payload)
    end
  end

  test "[unit] the unique run_id index blocks a duplicate insert" do
    GithubWorkflowRun.create!(run_id: RUN_ID, repo: "mcritchie/mcritchie-studio", status: "queued")

    assert_raises(ActiveRecord::RecordNotUnique) do
      GithubWorkflowRun
        .new(run_id: RUN_ID, repo: "mcritchie/other", status: "queued")
        .save!(validate: false)
    end
  end

  test "[unit] a failure inside the upsert is captured to ErrorLog, not re-raised" do
    GithubWorkflowRun.stub(:find_or_initialize_by, ->(*) { raise "upsert blew up" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_nothing_raised do
          ingest(status: "queued")
        end
      end
    end
    assert_equal RUN_ID.to_s, ErrorLog.order(:id).last.target_name
  end

  # ── deployment_review (pending-approval gate) ────────────────────────────

  # A deployment_review event, parameterized on action + environment.
  def review_event(action: "requested", environment: "production", run_id: RUN_ID, **run_overrides)
    {
      "action" => action,
      "environment" => environment,
      "since" => "2026-07-15T09:00:00Z",
      "workflow_run" => {
        "id" => run_id,
        "name" => "Production Deploy",
        "status" => "waiting",
        "head_sha" => "9f2c1b7ad4e5c60f1e2d3a4b5c6d7e8f90123456",
        "head_branch" => "release",
        "html_url" => "https://github.com/mcritchie/mcritchie-studio/actions/runs/#{run_id}",
        "run_started_at" => "2026-07-15T08:59:00Z"
      }.merge(run_overrides),
      "repository" => { "full_name" => "mcritchie/mcritchie-studio" }
    }
  end

  def ingest_review(event_name: "deployment_review", **kwargs)
    # Silence the Discord nudge unless a test explicitly asserts on it.
    Devops::DeployApprovalNotifier.stub(:notify_pending, true) do
      GithubWorkflowRunIngestJob.perform_now(event_name, review_event(**kwargs))
    end
  end

  test "[unit] deployment_review requested stamps the pending environment" do
    ingest_review

    run = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "production", run.pending_environment
    assert run.pending_approval?
    assert_not_nil run.pending_since
    assert_equal "Production Deploy", run.workflow_name
    assert_equal "mcritchie/mcritchie-studio", run.repo
  end

  test "[unit] deployment_review requested seeds a fresh row with an in_progress status floor" do
    assert_difference "GithubWorkflowRun.count", 1 do
      ingest_review
    end
    assert_equal "in_progress", GithubWorkflowRun.find_by(run_id: RUN_ID).status
  end

  test "[unit] deployment_review flags an existing workflow_run row without regressing status" do
    ingest(status: "completed", conclusion: "success")
    ingest_review

    run = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "completed", run.status, "the review flag must not disturb the status ladder"
    assert_equal "success", run.conclusion
    assert_equal "production", run.pending_environment
  end

  test "[unit] deployment_review approved clears the pending flag" do
    ingest_review
    assert GithubWorkflowRun.find_by(run_id: RUN_ID).pending_approval?

    ingest_review(action: "approved")
    assert_not GithubWorkflowRun.find_by(run_id: RUN_ID).pending_approval?
  end

  test "[unit] deployment_protection_rule requested is handled like deployment_review" do
    ingest_review(event_name: "deployment_protection_rule")
    assert_equal "production", GithubWorkflowRun.find_by(run_id: RUN_ID).pending_environment
  end

  test "[unit] a completed workflow_run clears a prior pending flag" do
    ingest_review
    assert GithubWorkflowRun.find_by(run_id: RUN_ID).pending_approval?

    ingest(status: "completed", conclusion: "success")
    assert_not GithubWorkflowRun.find_by(run_id: RUN_ID).pending_approval?
  end

  test "[unit] entering pending fires the Discord nudge exactly once" do
    calls = 0
    Devops::DeployApprovalNotifier.stub(:notify_pending, ->(_run) { calls += 1; true }) do
      GithubWorkflowRunIngestJob.perform_now("deployment_review", review_event)
      # A re-delivery of the same requested event must NOT re-ping (already pending).
      GithubWorkflowRunIngestJob.perform_now("deployment_review", review_event)
    end
    assert_equal 1, calls
  end

  test "[unit] approved/rejected reviews do not ping" do
    calls = 0
    Devops::DeployApprovalNotifier.stub(:notify_pending, ->(_run) { calls += 1; true }) do
      GithubWorkflowRunIngestJob.perform_now("deployment_review", review_event(action: "approved"))
    end
    assert_equal 0, calls
  end

  test "[unit] a review event missing a run id is skipped without a row" do
    payload = review_event
    payload["workflow_run"]["id"] = nil
    assert_no_difference "GithubWorkflowRun.count" do
      ingest_review_payload(payload)
    end
  end

  def ingest_review_payload(payload)
    Devops::DeployApprovalNotifier.stub(:notify_pending, true) do
      GithubWorkflowRunIngestJob.perform_now("deployment_review", payload)
    end
  end
end
