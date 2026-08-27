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

  test "[unit] a re-delivered completed event of the SAME attempt does not overwrite the conclusion" do
    ingest(status: "completed", conclusion: "success")
    # An at-least-once re-delivery carrying a different conclusion for the attempt
    # already recorded — refused, exactly as before run_attempt existed.
    ingest(status: "completed", conclusion: "failure")

    assert_equal "success", GithubWorkflowRun.find_by(run_id: RUN_ID).conclusion
  end

  # The regression this file now owns. GitHub re-runs a failed workflow under the
  # SAME run_id (bumping run_attempt), so a blanket first-write-wins pinned the row
  # at `failure` forever. Ci::ReviewGate reads these rows and nothing else, so
  # `bin/task claim-next-review` could never pop a PR whose flake a re-run had
  # already fixed — green on GitHub, permanently unclaimable on the board.
  test "[unit] a re-run's completed success supersedes the failed attempt" do
    ingest(status: "completed", conclusion: "failure", "run_attempt" => 1)
    # The re-run: same run_id, attempt 2 — GitHub replays in_progress first.
    ingest(status: "in_progress", "run_attempt" => 2)
    ingest(status: "completed", conclusion: "success", "run_attempt" => 2)

    record = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "success", record.conclusion, "the re-run's verdict must win"
    assert_equal 2, record.run_attempt
  end

  # Out-of-order is the norm, and this row AUTHORISES A MERGE — a stale attempt
  # landing a green over a real red is the unsafe direction, so the guard is the
  # attempt number, not merely "the delivery said completed".
  test "[unit] a late replay of an EARLIER attempt never overwrites a newer verdict" do
    ingest(status: "completed", conclusion: "failure", "run_attempt" => 2)
    ingest(status: "completed", conclusion: "success", "run_attempt" => 1)

    assert_equal "failure", GithubWorkflowRun.find_by(run_id: RUN_ID).conclusion,
                 "attempt 1 arriving late must not green a row attempt 2 failed"
    assert_equal 2, GithubWorkflowRun.find_by(run_id: RUN_ID).run_attempt
  end

  # Rows ingested before the column existed carry run_attempt nil. They were
  # attempt 1, so the first re-run must still be able to correct them.
  test "[unit] a re-run supersedes a legacy row that carries no run_attempt" do
    ingest(status: "completed", conclusion: "failure")
    assert_nil GithubWorkflowRun.find_by(run_id: RUN_ID).run_attempt

    ingest(status: "completed", conclusion: "success", "run_attempt" => 2)

    assert_equal "success", GithubWorkflowRun.find_by(run_id: RUN_ID).conclusion
  end

  # The property the old first-write-wins guard was actually written for — it must
  # survive the change.
  test "[unit] a non-terminal re-delivery still cannot wipe a conclusion back to nil" do
    ingest(status: "completed", conclusion: "success", "run_attempt" => 1)
    ingest(status: "in_progress", conclusion: nil, "run_attempt" => 1)

    assert_equal "success", GithubWorkflowRun.find_by(run_id: RUN_ID).conclusion
  end

  # THE UNCOVERED VECTOR (caught in review of this very change). A NON-TERMINAL
  # delivery can advance the stored attempt while the conclusion is still blank —
  # and a blank conclusion used to be filled by ANY delivery, including a stale
  # one. That let an older attempt's verdict land, after which the real attempt
  # was refused as "not newer". Both orders are reproduced below; the guard drops
  # an older attempt's delivery WHOLE, mirroring the monotonic status guard.
  test "[unit] a stale attempt cannot land a GREEN over a run that really failed" do
    ingest(status: "in_progress", "run_attempt" => 2) # advances the stored attempt
    ingest(status: "completed", conclusion: "success", "run_attempt" => 1) # late replay
    ingest(status: "completed", conclusion: "failure", "run_attempt" => 2) # the truth

    assert_equal "failure", GithubWorkflowRun.find_by(run_id: RUN_ID).conclusion,
                 "a stale attempt must never authorise a merge on a red run"
  end

  test "[unit] a stale attempt cannot pin the row RED after the re-run went green" do
    ingest(status: "in_progress", "run_attempt" => 2)
    ingest(status: "completed", conclusion: "failure", "run_attempt" => 1) # late replay
    ingest(status: "completed", conclusion: "success", "run_attempt" => 2) # the truth

    assert_equal "success", GithubWorkflowRun.find_by(run_id: RUN_ID).conclusion,
                 "this is the stuck-red bug the task exists to fix — it must not survive"
  end

  test "[unit] an older attempt's delivery is dropped whole, not partially applied" do
    ingest(status: "completed", conclusion: "success", "run_attempt" => 3)
    ingest(status: "completed", conclusion: "failure", "run_attempt" => 2)

    record = GithubWorkflowRun.find_by(run_id: RUN_ID)
    assert_equal "success", record.conclusion
    assert_equal 3, record.run_attempt, "the stored attempt must not regress either"
  end

  test "[unit] an unhandled event is ignored gracefully (no run, no check job)" do
    assert_no_difference ["GithubWorkflowRun.count", "CiCheckJob.count"] do
      GithubWorkflowRunIngestJob.perform_now("push", event(status: "queued"))
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

  # ── workflow_job (per-check LIVE progress) ───────────────────────────────
  JOB_ID = 555_123_456
  JOB_SHA = "9f2c1b7ad4e5c60f1e2d3a4b5c6d7e8f90123456"

  # A realistic workflow_job event, parameterized on the lifecycle status.
  def job_event(status:, conclusion: nil, job_id: JOB_ID, workflow_name: "CI", head_sha: JOB_SHA, **overrides)
    {
      "action" => (status == "completed" ? "completed" : status),
      "workflow_job" => {
        "id" => job_id,
        "run_id" => 987_654_321,
        "workflow_name" => workflow_name,
        "name" => "lint",
        "status" => status,
        "conclusion" => conclusion,
        "head_sha" => head_sha,
        "head_branch" => "feat/webhook-push-not-poll",
        "started_at" => "2026-07-15T12:00:10Z",
        "completed_at" => (status == "completed" ? "2026-07-15T12:01:40Z" : nil)
      }.merge(overrides),
      "repository" => { "full_name" => "McRitchie-Studio/mcritchie-studio" }
    }
  end

  def ingest_job(status:, **kwargs)
    GithubWorkflowRunIngestJob.perform_now("workflow_job", job_event(status: status, **kwargs))
  end

  test "[unit] a workflow_job delivery records a CiCheckJob row with the mapped fields" do
    assert_difference "CiCheckJob.count", 1 do
      ingest_job(status: "completed", conclusion: "success")
    end

    job = CiCheckJob.find_by(job_id: JOB_ID)
    assert_equal "McRitchie-Studio/mcritchie-studio", job.repo
    assert_equal 987_654_321, job.run_id
    assert_equal "CI", job.workflow_name
    assert_equal "lint", job.name
    assert_equal JOB_SHA, job.head_sha
    assert_equal "feat/webhook-push-not-poll", job.head_branch
    assert_equal "completed", job.status
    assert_equal "success", job.conclusion
    assert_not_nil job.started_at
    assert_not_nil job.completed_at
  end

  test "[unit] a re-delivered workflow_job is idempotent — no duplicate row" do
    2.times { ingest_job(status: "in_progress") }
    assert_equal 1, CiCheckJob.where(job_id: JOB_ID).count
    assert_equal "in_progress", CiCheckJob.find_by(job_id: JOB_ID).status
  end

  test "[unit] a workflow_job status advances queued -> in_progress -> completed" do
    ingest_job(status: "queued")
    ingest_job(status: "in_progress")
    ingest_job(status: "completed", conclusion: "success")

    job = CiCheckJob.find_by(job_id: JOB_ID)
    assert_equal "completed", job.status
    assert_equal "success", job.conclusion
  end

  test "[unit] a late in_progress re-delivery never regresses a completed check job" do
    ingest_job(status: "completed", conclusion: "failure")
    ingest_job(status: "in_progress", conclusion: nil)

    job = CiCheckJob.find_by(job_id: JOB_ID)
    assert_equal "completed", job.status, "monotonic: must not regress to in_progress"
    assert_equal "failure", job.conclusion, "conclusion is first-write-wins; must survive"
  end

  test "[unit] a re-delivered completed workflow_job does not overwrite the conclusion" do
    ingest_job(status: "completed", conclusion: "success")
    ingest_job(status: "completed", conclusion: "failure")
    assert_equal "success", CiCheckJob.find_by(job_id: JOB_ID).conclusion
  end

  test "[unit] a workflow_job outside the CI-suite allowlist is skipped — the table is for the CI meters only" do
    # A deploy workflow is not a CI-suite verdict, so it never gets a progress row.
    assert_no_difference "CiCheckJob.count" do
      ingest_job(status: "in_progress", workflow_name: "Production Deploy")
    end
  end

  test "[unit] a gem's own CI-suite workflow_job IS recorded, tagged with its workflow" do
    # studio-engine's "Engine CI" is a surfaced release track (GithubWorkflowRun::
    # CI_PROGRESS_WORKFLOWS), so its per-job progress must be recorded — and tagged
    # by workflow so the reader can fold it apart from a sibling "Consumer CI".
    assert_difference "CiCheckJob.count", 1 do
      ingest_job(status: "completed", conclusion: "success", job_id: JOB_ID + 7,
                 workflow_name: "Engine CI", head_sha: "engine-main-sha")
    end
    assert_equal "Engine CI", CiCheckJob.find_by(head_sha: "engine-main-sha").workflow_name
  end

  test "[unit] a gem's declared SIBLING lane IS recorded, tagged apart from its own suite" do
    # "Consumer CI" runs the DOWNSTREAM apps' suites on the same gem SHA. It is not the
    # gem's own verdict — and it was outside the allowlist for exactly that reason,
    # which left the board unable to draw a lane it was already naming in prose: a
    # green 3/3 "Engine CI" meter beside an amber pill for six minutes while these
    # jobs ran. Recording it does NOT blend it: the row carries its workflow_name, and
    # every fold that must stay narrow still asks for one.
    assert_difference "CiCheckJob.count", 1 do
      ingest_job(status: "in_progress", job_id: JOB_ID + 11,
                 workflow_name: "Consumer CI", head_sha: "engine-release-sha")
    end
    assert_equal "Consumer CI", CiCheckJob.find_by(head_sha: "engine-release-sha").workflow_name,
                 "tagged, so a narrow reader can still exclude it"
  end

  test "[unit] the allowlist is DERIVED from the registry, not hand-listed" do
    # The bug this guards is the one that produced the narrow allowlist in the first
    # place: a lane declared in one place and forgotten in the other. Declaring a
    # sibling suite is what ingests it — nobody has to remember a second list.
    Release::AcceptedCertification::SIBLING_SUITE_WORKFLOWS.each_value do |lanes|
      lanes.each do |lane|
        assert_includes GithubWorkflowRun::CI_PROGRESS_WORKFLOWS, lane,
                        "#{lane.inspect} is a declared suite lane the ingest would drop — its per-job " \
                        "progress could never reach a meter"
      end
    end
  end

  test "[unit] a workflow_job missing head_sha is skipped (the fold is SHA-keyed)" do
    assert_no_difference "CiCheckJob.count" do
      ingest_job(status: "queued", head_sha: nil)
    end
  end

  test "[unit] a workflow_job missing its id is skipped without a row" do
    payload = job_event(status: "queued")
    payload["workflow_job"]["id"] = nil
    assert_no_difference "CiCheckJob.count" do
      GithubWorkflowRunIngestJob.perform_now("workflow_job", payload)
    end
  end

  test "[unit] eight completed CI jobs for a SHA fold into a full 8/8 bar" do
    8.times { |i| ingest_job(status: "completed", conclusion: "success", job_id: 700 + i, name: "check-#{i}") }
    rows = CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", JOB_SHA)
    assert_equal "8 / 8", Ci::CheckProgress.from_check_runs(rows).fraction_label
  end

  test "[integration] a re-run does not duplicate the live count — the fold resets fresh" do
    # Attempt 1: four distinct checks complete green under run 111.
    4.times { |i| ingest_job(status: "completed", conclusion: "success", job_id: 800 + i, name: "check-#{i}", run_id: 111) }
    rows = CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", JOB_SHA)
    assert_equal "4 / 4", Ci::CheckProgress.from_check_runs(rows).fraction_label

    # A re-run (new workflow_run 222) re-queues the SAME four checks with NEW job_ids.
    4.times { |i| ingest_job(status: "in_progress", job_id: 900 + i, name: "check-#{i}", run_id: 222) }
    rows = CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", JOB_SHA)

    assert_equal 8, CiCheckJob.where(head_sha: JOB_SHA).count, "both attempts' rows persist in the table"
    assert_equal "0 / 4", Ci::CheckProgress.from_check_runs(rows).fraction_label,
      "the fold RESETS to the four latest-attempt checks — never accumulates to 8"
  end

  test "[unit] a failure inside the check-job upsert is captured to ErrorLog, not re-raised" do
    CiCheckJob.stub(:find_or_initialize_by, ->(*) { raise "check-job upsert blew up" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_nothing_raised { ingest_job(status: "queued") }
      end
    end
    assert_equal JOB_ID.to_s, ErrorLog.order(:id).last.target_name
  end
end
