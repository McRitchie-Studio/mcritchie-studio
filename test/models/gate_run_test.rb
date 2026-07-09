require "test_helper"

class GateRunTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:new_task)
  end

  def open_gate(key: "g1_cert", **args)
    GateRun.open!(subject_type: "task", subject_slug: @task.slug, key: key, **args)
  end

  test "open! creates attempt 1 in flight" do
    run = open_gate(actor: "carl", source: "cli")

    assert_equal 1, run.attempt
    assert run.in_flight?
    assert_equal "in_flight", run.status
    assert_nil run.success
    assert_equal "carl", run.actor
    assert_equal [], run.sops
  end

  test "open! is idempotent while an attempt is in flight" do
    first = open_gate
    second = open_gate

    assert_equal first.id, second.id
    assert_equal 1, GateRun.for_subject("task", @task.slug).count
  end

  test "close! records the verdict and merges sops onto the open attempt" do
    open_gate
    GateRun.append_sop!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert",
                        sop: { "sop" => "full-suite", "result" => "pass", "duration_ms" => "8123" })

    run = GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert",
                         success: true, sops: [{ "sop" => "dor-check", "result" => "pass" }])

    assert_not run.in_flight?
    assert run.success
    assert_equal "passed", run.status
    assert_equal %w[full-suite dor-check], run.sops.map { |s| s["sop"] }
    assert_equal 8123, run.sops.first["duration_ms"]
    assert run.sops.all? { |s| s["at"].present? }, "every sops entry is at-stamped"
  end

  test "open! after a close starts attempt n+1" do
    open_gate
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: false)

    run = open_gate

    assert_equal 2, run.attempt
    assert run.in_flight?
  end

  # Regression: after_create_commit + after_update_commit with the SAME method
  # name dedupe to the last registration (Rails callback-chain behavior), which
  # silently dropped the create hook — a gate OPEN never broadcast. The single
  # after_save_commit must fire on BOTH the open (create) and the close (update).
  test "[unit] open and close both broadcast the gate run" do
    calls = []
    DeploymentsBroadcaster.stub(:gate_run, ->(run) { calls << run.status }) do
      open_gate
      GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: true)
    end

    assert_includes calls, "in_flight", "the OPEN (create commit) must broadcast"
    assert_includes calls, "passed", "the CLOSE (update commit) must broadcast"
  end

  test "close! with no open attempt records a self-contained attempt" do
    run = GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: false)

    assert_equal 1, run.attempt
    assert_equal "failed", run.status
    assert_equal run.started_at, run.finished_at
  end

  test "append_sop! implicitly opens an attempt" do
    run = GateRun.append_sop!(subject_type: "task", subject_slug: @task.slug, key: "g2a_primary",
                              sop: { "sop" => "dor-check", "result" => "pass" })

    assert run.in_flight?
    assert_equal 1, run.attempt
    assert_equal ["dor-check"], run.sops.map { |s| s["sop"] }
  end

  test "normalize_sop slices to the known keys" do
    run = GateRun.append_sop!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert",
                              sop: { "sop" => "rubocop", "result" => "pass", "sneaky" => "dropped" })

    entry = run.sops.first
    assert_equal "rubocop", entry["sop"]
    assert_not entry.key?("sneaky")
  end

  test "a task-grain key rejects a release subject and vice versa" do
    release_grain = GateRun.new(subject_type: "release", subject_slug: "rel-x", key: "g1_cert",
                                attempt: 1, started_at: Time.current)
    task_grain = GateRun.new(subject_type: "task", subject_slug: @task.slug, key: "g3_candidate",
                             attempt: 1, started_at: Time.current)

    assert_not release_grain.valid?
    assert_match(/task-grain/, release_grain.errors[:key].first)
    assert_not task_grain.valid?
    assert_match(/release-grain/, task_grain.errors[:key].first)
  end

  test "unknown keys and subject types are rejected" do
    run = GateRun.new(subject_type: "sprocket", subject_slug: "x", key: "g9_vibes",
                      attempt: 1, started_at: Time.current)

    assert_not run.valid?
    assert run.errors[:subject_type].any?
    assert run.errors[:key].any?
  end

  test "latest_by_key returns the newest attempt per gate" do
    open_gate
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: false)
    open_gate
    GateRun.open!(subject_type: "task", subject_slug: @task.slug, key: "g2b_light")

    latest = GateRun.latest_by_key(subject_type: "task", subject_slug: @task.slug)

    assert_equal 2, latest["g1_cert"].attempt
    assert_equal 1, latest["g2b_light"].attempt
    assert_nil latest["g2a_primary"]
  end

  test "[unit] latest_by_key_for_subjects batches newest attempts per slug" do
    other = tasks(:queued_task)
    open_gate
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: false)
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: true)
    GateRun.open!(subject_type: "task", subject_slug: other.slug, key: "g2a_primary")

    by_slug = GateRun.latest_by_key_for_subjects(
      subject_type: "task",
      subject_slugs: [@task.slug, other.slug, "slug-with-no-runs"]
    )

    assert_equal 2, by_slug[@task.slug]["g1_cert"].attempt, "newest attempt wins per key"
    assert_equal "passed", by_slug[@task.slug]["g1_cert"].status
    assert_equal "in_flight", by_slug[other.slug]["g2a_primary"].status
    assert_nil by_slug[@task.slug]["g2b_light"]
    assert_nil by_slug["slug-with-no-runs"], "a subject with no runs has no entry"
  end

  test "duration_seconds measures a closed attempt and ticks an open one" do
    run = open_gate
    run.update!(started_at: 90.seconds.ago)

    assert run.duration_seconds >= 90

    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: true)
    assert run.reload.duration_seconds >= 90
  end

  test "one in-flight attempt per subject and gate is enforced by the index" do
    open_gate

    assert_raises(ActiveRecord::RecordNotUnique) do
      GateRun.insert_all!([{
        subject_type: "task", subject_slug: @task.slug, key: "g1_cert", attempt: 5,
        started_at: Time.current, sops: [], metadata: {},
        created_at: Time.current, updated_at: Time.current
      }])
    end
  end

  test "task association scopes to task-grain runs and deletes with the task" do
    run = open_gate

    assert_includes @task.gate_runs, run

    @task.destroy!
    assert_not GateRun.exists?(run.id)
  end
end
