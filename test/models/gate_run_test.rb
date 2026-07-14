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

  test "normalize_sop preserves unreadable CI evidence" do
    run = GateRun.append_sop!(subject_type: "task", subject_slug: @task.slug, key: "dor_review",
                              sop: { "sop" => "ci", "result" => "unverified", "state" => "unreadable",
                                     "cause" => "permissions", "reason" => "access denied",
                                     "repo" => "amcritchie/rolio" })

    entry = run.sops.first
    assert_equal "unreadable", entry["state"]
    assert_equal "permissions", entry["cause"]
    assert_equal "access denied", entry["reason"]
    assert_equal "amcritchie/rolio", entry["repo"]
  end

  test "[unit] GATES include the two DoR gates in flow order between g1_cert and g2a" do
    assert_equal %w[g1_cert dor dor_review g2a_primary g2b_light g3_candidate g4_ship], GateRun::KEYS
    assert_equal %w[g1_cert dor dor_review g2a_primary g2b_light], GateRun::TASK_KEYS

    %w[dor dor_review].each do |key|
      assert_equal "task", GateRun::GATES.dig(key, "grain")
      run = GateRun.new(subject_type: "task", subject_slug: @task.slug, key: key,
                        attempt: 1, started_at: Time.current)
      assert run.valid?, "#{key} is a valid task-grain gate: #{run.errors.full_messages}"
    end
  end

  test "[unit] opening a g1_cert task gate stamps tasks.g1_testing_started_at" do
    assert_nil @task.g1_testing_started_at

    freeze_time do
      open_gate
      assert_equal Time.current, @task.reload.g1_testing_started_at
      assert_nil @task.g1_testing_finished_at
      assert_nil @task.g1_failed_at
    end
  end

  test "[unit] closing g1_cert --success stamps finished_at and leaves g1_failed_at nil" do
    open_gate
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: true)

    @task.reload
    assert @task.g1_testing_started_at.present?
    assert @task.g1_testing_finished_at.present?
    assert_nil @task.g1_failed_at, "a green close clears g1_failed_at"
  end

  test "[unit] closing g1_cert --failed stamps g1_failed_at, a green retry clears it" do
    open_gate
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: false)
    assert @task.reload.g1_failed_at.present?, "a red close sets g1_failed_at"

    open_gate # attempt 2
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: true)
    assert_nil @task.reload.g1_failed_at, "a green retry clears g1_failed_at"
  end

  test "[unit] a non-g1_cert gate does not stamp the g1 testing window columns" do
    open_gate(key: "dor")
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "dor", success: false)

    @task.reload
    assert_nil @task.g1_testing_started_at
    assert_nil @task.g1_testing_finished_at
    assert_nil @task.g1_failed_at, "a red DoR close must NOT touch g1_failed_at"
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
