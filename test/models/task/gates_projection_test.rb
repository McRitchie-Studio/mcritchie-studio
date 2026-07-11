require "test_helper"

class Task::GatesProjectionTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:new_task)
  end

  def open_gate(key: "g1_cert", **args)
    GateRun.open!(subject_type: "task", subject_slug: @task.slug, key: key, **args)
  end

  def close_gate(key: "g1_cert", success: true, **args)
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: key, success: success, **args)
  end

  test "[unit] build snapshots the LATEST attempt per task gate" do
    open_gate
    close_gate(success: false)
    open_gate # attempt 2, in flight
    close_gate(key: "g2a_primary", success: true,
               sops: [{ "sop" => "pr-review-primary", "result" => "pass", "duration_ms" => 4200 }])

    gates = Task::GatesProjection.build(@task).fetch("gates")

    assert_equal 2, gates.dig("g1_cert", "attempt"), "attempt 2 supersedes the failed attempt 1"
    assert_nil gates.dig("g1_cert", "success"), "in-flight attempt has no verdict yet"
    assert gates.dig("g1_cert", "started_at").present?
    assert_nil gates.dig("g1_cert", "finished_at")

    assert_equal 1, gates.dig("g2a_primary", "attempt")
    assert_equal true, gates.dig("g2a_primary", "success")
    assert_equal ["pr-review-primary"], gates.dig("g2a_primary", "sops").map { |s| s["sop"] }
  end

  test "[unit] every task-grain gate key is present even when never attempted" do
    gates = Task::GatesProjection.build(@task).fetch("gates")

    assert_equal GateRun::TASK_KEYS.sort, gates.keys.sort
    GateRun::TASK_KEYS.each do |key|
      assert_nil gates.dig(key, "attempt"), "#{key} never ran -> all-nil row"
      assert_equal [], gates.dig(key, "sops")
    end
  end

  test "[unit] VERSION is bumped to 2 so cached 3-key projections self-heal" do
    assert_equal 2, Task::GatesProjection::VERSION
  end

  test "[unit] the two DoR gates project as all-nil rows when unrun and carry attempts when run" do
    gates = Task::GatesProjection.build(@task).fetch("gates")
    %w[dor dor_review].each do |key|
      assert gates.key?(key), "#{key} is a projected task-grain gate"
      assert_nil gates.dig(key, "attempt"), "#{key} unrun -> all-nil row"
    end

    open_gate(key: "dor")
    close_gate(key: "dor", success: true, sops: [{ "sop" => "dor-check", "result" => "pass" }])
    GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "dor_review", success: false)

    gates = Task::GatesProjection.build(@task).fetch("gates")
    assert_equal 1, gates.dig("dor", "attempt")
    assert_equal true, gates.dig("dor", "success")
    assert_equal ["dor-check"], gates.dig("dor", "sops").map { |s| s["sop"] }
    assert_equal false, gates.dig("dor_review", "success")
  end

  test "[unit] release-grain gates are excluded from the projection" do
    GateRun.close!(subject_type: "release", subject_slug: "rel-probe", key: "g3_candidate", success: true)

    gates = Task::GatesProjection.build(@task).fetch("gates")
    assert_not_includes gates.keys, "g3_candidate", "release-grain stays out of the task projection"
    assert_not_includes gates.keys, "g4_ship"
  end

  test "[unit] refresh! persists the projection at the current version" do
    close_gate(success: true)
    Task::GatesProjection.refresh!(@task)
    @task.reload

    assert_equal Task::GatesProjection::VERSION, @task.gates_version
    assert @task.gates_cached_at.present?
    assert_equal true, @task.gates.dig("gates", "g1_cert", "success")
  end

  test "[unit] cached_or_built serves the cache at the current version" do
    sentinel = { "cache_version" => Task::GatesProjection::VERSION, "gates" => { "sentinel" => true } }
    @task.update_columns(gates: sentinel, gates_version: Task::GatesProjection::VERSION)

    assert_equal sentinel, Task::GatesProjection.cached_or_built(@task.reload), "current version -> cache served"
  end

  test "[unit] cached_or_built rebuilds when the stored version is stale" do
    close_gate(success: true)
    @task.update_columns(gates: { "gates" => {} }, gates_version: 0)

    rebuilt = Task::GatesProjection.cached_or_built(@task.reload)
    assert_equal true, rebuilt.dig("gates", "g1_cert", "success"), "version 0 -> rebuild from gate_runs"
  end

  test "[unit] cached_or_built returns a safe empty projection when build fails" do
    @task.update_columns(gates_version: 0) # force the build path

    Task::GatesProjection.stub(:build, ->(*) { raise "boom" }) do
      result = Task::GatesProjection.cached_or_built(@task.reload)
      assert_equal Task::GatesProjection::VERSION, result["cache_version"]
      assert_nil result.dig("gates", "g1_cert", "attempt"), "degrades to all-empty, no raise"
    end
  end

  # Drive the REAL write funnel (open!/append_sop!/close! — what the API controller
  # and the release conductor call) and confirm the commit hooks keep the persisted
  # projection in step at every step.
  test "[integration] gate run writes refresh the parent task projection" do
    open_gate
    assert_equal 1, @task.reload.gates.dig("gates", "g1_cert", "attempt"), "open! refreshes"
    assert_nil @task.gates.dig("gates", "g1_cert", "success")

    GateRun.append_sop!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert",
                        sop: { "sop" => "full-suite", "result" => "pass" })
    assert_equal ["full-suite"], @task.reload.gates.dig("gates", "g1_cert", "sops").map { |s| s["sop"] },
                 "append_sop! refreshes"

    close_gate(success: true)
    @task.reload
    assert_equal true, @task.gates.dig("gates", "g1_cert", "success"), "close! refreshes with the verdict"
    assert @task.gates.dig("gates", "g1_cert", "finished_at").present?
    assert_equal Task::GatesProjection::VERSION, @task.gates_version
  end

  test "[integration] a release-grain gate run write does not touch task rows" do
    before = @task.reload.updated_at
    GateRun.close!(subject_type: "release", subject_slug: "rel-probe", key: "g4_ship", success: true)

    assert_equal before, @task.reload.updated_at, "release-grain hook returns early"
  end
end
