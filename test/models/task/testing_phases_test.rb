require "test_helper"

class Task::TestingPhasesTest < ActiveSupport::TestCase
  # A task whose durable events make each phase a clean, exactly-measured window:
  # build 600s (building → first cert start), cert 300s, submitted at +20m and
  # reviewed at +33m. Review/CI evidence (gate runs, intents, CI actions) is layered
  # on per test, so each v2 boundary rule is exercised in isolation.
  def probe_task
    @anchor = 60.minutes.ago
    task = Task.create!(title: "Phase Timing Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: @anchor)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "started",   at: @anchor + 10.minutes)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "completed", at: @anchor + 15.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: @anchor + 20.minutes)
    add_event(task, kind: "transition", to_stage: "reviewed",  at: @anchor + 33.minutes)
    task
  end

  def add_event(task, kind:, to_stage:, at:, status: nil)
    task.task_events.create!(kind: kind, from_stage: task.stage, to_stage: to_stage,
                             occurred_at: at, seconds_in_from: nil, source: "test",
                             metadata: status ? { "status" => status } : {})
  end

  def add_ci_action(task, event_slug:, at:, duration_ms: 60_000)
    AgentAction.create!(session_id: "sess-ci-probe", kind: "test_scope", event_slug: event_slug,
                        result_slug: "pass", task_slug: task.slug, occurred_at: at,
                        duration_ms: duration_ms)
  end

  def open_review_gate(task, key: "g2a_primary", at:)
    GateRun.open!(subject_type: "task", subject_slug: task.slug, key: key, actor: "carl", now: at)
  end

  test "[unit] build derives the four task-owned phase windows from events + gate runs + CI actions" do
    task = probe_task
    add_ci_action(task, event_slug: "ci_lint", at: @anchor + 25.minutes)
    add_ci_action(task, event_slug: "ci_test", at: @anchor + 27.minutes)
    open_review_gate(task, at: @anchor + 22.minutes)

    phases = Task::TestingPhases.build(task).fetch("phases")

    assert_equal Task::TestingPhases::PHASE_KEYS, phases.keys, "exactly the four v2 phases, in order"
    assert_equal 600, phases.dig("build", "seconds"), "building -> first cert start"
    assert_equal "completed", phases.dig("build", "status")
    assert_equal 300, phases.dig("local_certification", "seconds"), "cert started -> cert finished"
    assert_equal 420, phases.dig("ci", "seconds"), "submitted handoff -> last CI action settle"
    assert_equal 660, phases.dig("review", "seconds"), "gate-run start -> reviewed, NOT submitted -> reviewed"
    refute phases.key?("acceptance"), "operator acceptance is no longer a task phase"
  end

  test "[unit] review starts at the earliest G2 lane when both review gates ran" do
    task = probe_task
    open_review_gate(task, key: "g2a_primary", at: @anchor + 26.minutes)
    open_review_gate(task, key: "g2b_light",   at: @anchor + 22.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "gate_run", review["source"]
    assert_equal 660, review["seconds"], "the earlier lane (g2b at +22m) IS review start"
  end

  test "[unit] review falls back to the review intent when no gate runs exist" do
    task = probe_task
    add_event(task, kind: "intent", to_stage: "reviewed", at: @anchor + 23.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "intent", review["source"]
    assert_equal 600, review["seconds"], "reviewer-select intent -> reviewed"
  end

  test "[unit] a completed legacy review falls back to the submitted transition" do
    review = Task::TestingPhases.build(probe_task).dig("phases", "review")

    assert_equal "transition", review["source"], "no gate run, no intent, reviewed landed -> v1 semantics"
    assert_equal "completed", review["status"]
    assert_equal 780, review["seconds"], "submitted -> reviewed keeps its measured window on the version bump"
  end

  test "[unit] a submitted task with no review evidence reports review missing" do
    task = Task.create!(title: "Queued Review Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: 50.minutes.ago)
    add_event(task, kind: "transition", to_stage: "submitted", at: 40.minutes.ago)
    task.update_columns(stage: "submitted") # rubocop:disable Rails/SkipsModelValidations

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "missing", review["status"], "queue time is the visible gap, not a fake review window"
    assert_nil review["started_at"]
  end

  test "[unit] ci spans the submission handoff until captured checks settle" do
    task = probe_task
    add_ci_action(task, event_slug: "ci_lint", at: @anchor + 25.minutes)
    add_ci_action(task, event_slug: "ci_test", at: @anchor + 27.minutes)

    ci = Task::TestingPhases.build(task).dig("phases", "ci")
    assert_equal "completed", ci["status"]
    assert_equal "ci_approx", ci["source"]
    assert_equal (@anchor + 20.minutes).iso8601, ci["started_at"], "CI starts at the submitted handoff"
    assert_equal 420, ci["seconds"], "handoff (+20m) -> latest CI action (+27m)"
  end

  test "[unit] a task sitting in submitted with no CI evidence ticks in_progress" do
    task = Task.create!(title: "Open Handoff Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: 50.minutes.ago)
    add_event(task, kind: "transition", to_stage: "submitted", at: 40.minutes.ago)
    task.update_columns(stage: "submitted") # rubocop:disable Rails/SkipsModelValidations

    ci = Task::TestingPhases.build(task).dig("phases", "ci")
    assert_equal "in_progress", ci["status"], "the handoff window stays open while the task sits submitted"
    assert_in_delta 2400, ci["seconds"], 5
  end

  test "[unit] a task that left submitted with no CI evidence reports ci missing" do
    ci = Task::TestingPhases.build(probe_task).dig("phases", "ci")

    assert_equal "missing", ci["status"],
                 "legacy tasks recompute cleanly — no eternal in_progress CI after the version bump"
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

  # The VERSION 2 self-heal: a v1 row (five phases, review anchored to submitted)
  # rebuilds with v2 boundaries the first time it is read — no backfill required.
  test "[unit] cached_or_built rebuilds a stale v1 projection to v2 boundaries" do
    task = probe_task
    open_review_gate(task, at: @anchor + 22.minutes)
    task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      testing_phases_version: 1,
      testing_phases: { "cache_version" => 1, "phases" => {
        "review" => { "status" => "completed", "seconds" => 780, "source" => "transition" },
        "acceptance" => { "status" => "completed", "seconds" => 300, "source" => "approval" }
      } }
    )

    rebuilt = Task::TestingPhases.cached_or_built(task.reload)
    assert_equal Task::TestingPhases::VERSION, rebuilt["cache_version"]
    refute rebuilt["phases"].key?("acceptance"), "the v1 acceptance window does not survive the rebuild"
    assert_equal "gate_run", rebuilt.dig("phases", "review", "source")
    assert_equal 660, rebuilt.dig("phases", "review", "seconds"), "review re-anchors to actual review start"
  end

  test "[unit] approval_approved_at is stamped when approval flips to approved" do
    task = Task.create!(title: "Approval Stamp Probe")
    assert_nil task.devops["approval_approved_at"]

    task.update!(metadata: task.metadata.deep_merge("devops" => { "approval_status" => "approved" }))

    assert task.reload.devops["approval_approved_at"].present?,
           "the operator-acceptance stamps survive v2 — they just no longer project as a phase"
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
  # (record_checkpoint_event, what the API + bin/full-suite-check call), the review
  # intent (bin/reviewer-select), and the G2 gate run (the review supervisor) — and
  # confirm they flow through build + the persisted projection.
  test "[integration] real write paths populate the projection through the database" do
    task = Task.create!(title: "Producer Flow Probe")
    task.update!(stage: "building")
    task.record_checkpoint_event(name: "cert", status: "started")
    task.record_checkpoint_event(name: "cert", status: "completed")
    task.update!(stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: %w[carl shannon])
    GateRun.open!(subject_type: "task", subject_slug: task.slug, key: "g2a_primary", actor: "carl")
    task.update!(stage: "reviewed")

    phases = Task::TestingPhases.build(task.reload).fetch("phases")
    assert_equal "completed", phases.dig("local_certification", "status"), "cert start+finish paired"
    assert_equal "completed", phases.dig("review", "status"), "review start -> reviewed"
    assert_equal "gate_run", phases.dig("review", "source"), "the gate run outranks the intent"
    assert_equal "missing", phases.dig("ci", "status"), "left submitted with no captured CI evidence"
    refute phases.key?("acceptance"), "no acceptance phase on the v2 projection"

    task.refresh_testing_phases!
    reloaded = Task.find_by!(slug: task.slug)
    assert_equal Task::TestingPhases::VERSION, reloaded.testing_phases_version
    assert_equal "completed", reloaded.testing_phases.dig("phases", "review", "status"),
                 "the persisted projection round-trips through the DB"
  end
end
