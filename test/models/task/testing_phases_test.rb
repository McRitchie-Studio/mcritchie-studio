require "test_helper"

class Task::TestingPhasesTest < ActiveSupport::TestCase
  # A task whose durable events + approval stamps make each of the five task-owned
  # phases a clean, exactly-measured window (build 600s, cert 300s, review 600s,
  # acceptance 300s), with no CI actions.
  def probe_task
    anchor = 60.minutes.ago
    task = Task.create!(title: "Phase Timing Probe", metadata: { "devops" => {
      "approval_requested_at" => (anchor + 35.minutes).iso8601,
      "approval_approved_at" => (anchor + 40.minutes).iso8601
    } })
    add_event(task, kind: "transition", to_stage: "building",  at: anchor)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "started",   at: anchor + 10.minutes)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "completed", at: anchor + 15.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: anchor + 20.minutes)
    add_event(task, kind: "transition", to_stage: "reviewed",  at: anchor + 30.minutes)
    task
  end

  def add_event(task, kind:, to_stage:, at:, status: nil)
    task.task_events.create!(kind: kind, from_stage: task.stage, to_stage: to_stage,
                             occurred_at: at, seconds_in_from: nil, source: "test",
                             metadata: status ? { "status" => status } : {})
  end

  test "[unit] build derives the five task-owned phase windows from events + approval" do
    phases = Task::TestingPhases.build(probe_task).fetch("phases")

    assert_equal 600, phases.dig("build", "seconds"), "building -> first cert start"
    assert_equal "completed", phases.dig("build", "status")
    assert_equal 300, phases.dig("local_certification", "seconds"), "cert started -> cert finished"
    assert_equal 600, phases.dig("review", "seconds"), "submitted -> reviewed"
    assert_equal 300, phases.dig("acceptance", "seconds"), "approval requested -> approved"
    assert_equal "missing", phases.dig("ci", "status"), "no CI actions yet"
  end

  test "[unit] build falls back to the submitted transition when no cert ran" do
    anchor = 30.minutes.ago
    task = Task.create!(title: "No Cert Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: anchor)
    add_event(task, kind: "transition", to_stage: "submitted", at: anchor + 12.minutes)

    build = Task::TestingPhases.build(task).dig("phases", "build")
    assert_equal "completed", build["status"]
    assert_equal 720, build["seconds"], "building -> submitted (no cert checkpoint)"
  end

  test "[unit] an unfinished phase reports in_progress measured against now" do
    task = Task.create!(title: "Open Cert Probe")
    add_event(task, kind: "transition", to_stage: "building", at: 20.minutes.ago)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "started", at: 10.minutes.ago)

    cert = Task::TestingPhases.build(task).dig("phases", "local_certification")
    assert_equal "in_progress", cert["status"]
    assert_in_delta 600, cert["seconds"], 5, "roughly ten minutes of open cert"
  end

  test "[unit] refresh! persists the projection at the current version" do
    Task::TestingPhases.refresh!(task = probe_task)
    task.reload

    assert_equal Task::TestingPhases::VERSION, task.testing_phases_version
    assert task.testing_phases_cached_at.present?
    assert_equal 300, task.testing_phases.dig("phases", "local_certification", "seconds")
  end

  test "[unit] cached_or_built rebuilds when the stored version is stale" do
    task = probe_task
    task.update_columns(testing_phases: { "phases" => {} }, testing_phases_version: 0)

    rebuilt = Task::TestingPhases.cached_or_built(task.reload)
    assert_equal 300, rebuilt.dig("phases", "local_certification", "seconds"), "version 0 -> rebuild"
  end

  test "[unit] approval_approved_at is stamped when approval flips to approved" do
    task = Task.create!(title: "Approval Stamp Probe")
    assert_nil task.devops["approval_approved_at"]

    task.update!(metadata: task.metadata.deep_merge("devops" => { "approval_status" => "approved" }))

    assert task.reload.devops["approval_approved_at"].present?, "approved_at stamped on the flip"
  end

  # Fix (review): the after_commit refresh must NOT fire on metadata churn that
  # can't move a phase window — e.g. the statusline heartbeat rewriting claim_*.
  test "[unit] a heartbeat-style metadata change does not rebuild the projection" do
    task = probe_task
    task.update_columns(testing_phases: { "sentinel" => true }, testing_phases_version: 99)

    task.update!(metadata: task.metadata.deep_merge("devops" => {
      "claim_nonce" => "beef", "claim_expires_at" => 5.minutes.from_now.iso8601
    }))

    task.reload
    assert_equal 99, task.testing_phases_version, "heartbeat/claim churn must NOT rebuild"
    assert_equal({ "sentinel" => true }, task.testing_phases)
  end

  test "[unit] an approval metadata change DOES rebuild the projection" do
    task = probe_task
    task.update_columns(testing_phases: { "sentinel" => true }, testing_phases_version: 99)

    task.update!(metadata: task.metadata.deep_merge("devops" => { "approval_status" => "approved" }))

    task.reload
    assert_equal Task::TestingPhases::VERSION, task.testing_phases_version, "approval change rebuilds"
    refute_equal({ "sentinel" => true }, task.testing_phases)
  end

  # Fix (review): cached_or_built must never re-raise into a render — a failed
  # build returns a safe all-missing projection, not the same failing call.
  test "[unit] cached_or_built returns a safe empty projection when build fails" do
    task = probe_task
    task.update_columns(testing_phases_version: 0) # force the build path

    Task::TestingPhases.stub(:build, ->(*) { raise "boom" }) do
      result = Task::TestingPhases.cached_or_built(task.reload)
      assert_equal Task::TestingPhases::VERSION, result["cache_version"]
      assert_equal "missing", result.dig("phases", "build", "status"), "degrades to all-missing, no raise"
    end
  end

  # Drive the REAL write paths a producer uses — stage transitions, cert checkpoints
  # (record_checkpoint_event, what the API + bin/full-suite-check call), and the
  # approval stamps — and confirm they flow through build + the persisted projection.
  test "[integration] real write paths populate the projection through the database" do
    task = Task.create!(title: "Producer Flow Probe")
    task.update!(stage: "building")
    task.record_checkpoint_event(name: "cert", status: "started")
    task.record_checkpoint_event(name: "cert", status: "completed")
    task.update!(stage: "submitted")
    task.update!(stage: "reviewed")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "approval_status" => "waiting" }))
    task.update!(metadata: task.metadata.deep_merge("devops" => { "approval_status" => "approved" }))

    phases = Task::TestingPhases.build(task.reload).fetch("phases")
    assert_equal "completed", phases.dig("local_certification", "status"), "cert start+finish paired"
    assert_equal "completed", phases.dig("review", "status"), "submitted -> reviewed"
    assert_equal "completed", phases.dig("acceptance", "status"), "requested -> approved via stamps"

    task.refresh_testing_phases!
    reloaded = Task.find_by!(slug: task.slug)
    assert_equal Task::TestingPhases::VERSION, reloaded.testing_phases_version
    assert_equal "completed", reloaded.testing_phases.dig("phases", "acceptance", "status"),
                 "the persisted projection round-trips through the DB"
  end
end
