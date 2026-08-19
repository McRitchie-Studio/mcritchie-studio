require "test_helper"

# Unit tier (backend shape): the test-harness worker-count decision — single-process
# locally (pg fork-safety), parallel in CI, PARALLEL_WORKERS overrides either way.
class TestParallelismTest < ActiveSupport::TestCase
  test "defaults to single-process locally (no CI, no override)" do
    assert_equal 1, TestParallelism.worker_count({})
  end

  test "uses all processors in CI" do
    assert_equal :number_of_processors, TestParallelism.worker_count({ "CI" => "true" })
  end

  # CHANGED 2026-08-18 (/tasks/measure-local-parallel-workers). This used to assert
  # that PARALLEL_WORKERS=4 was honoured LOCALLY. Measured on a quiet machine, 2 of 2
  # trials, that request does not produce a parallel run — it produces four
  # `pg/connection.rb:944 [BUG] Segmentation fault` dumps at the fork, before any test
  # runs, plus orphan workers holding the test DB. So the old assertion pinned a
  # setting that could only ever crash. The override still works in CI, where forking
  # is fine, and still works locally to force 1.
  test "PARALLEL_WORKERS is honoured in CI and can always force single-process" do
    assert_equal 4, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "4", "CI" => "true" })
    assert_equal 1, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "1", "CI" => "true" })
    assert_equal 1, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "1" })
  end

  test "a local request for more than one worker is clamped, not obeyed" do
    out, err = capture_io do
      assert_equal 1, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "4" })
    end

    # The clamp is worthless if it is silent: the whole point is that the agent who
    # asked for 4 learns WHY they got 1, instead of reading a crash dump.
    assert_match(/PARALLEL_WORKERS=4 ignored locally/, "#{out}#{err}")
    assert_match(/SEGFAULT|segfault/i, "#{out}#{err}", "the warning must name the failure it is preventing")
    assert_match(/NOT a problem with your diff/, "#{out}#{err}",
                 "an ENV limitation must say so — this codebase's certs already learned that lesson")
  end

  test "the unsafe override restores the requested count for re-measurement" do
    # The one sanctioned way back in: re-running the experiment after a Ruby, pg, or
    # macOS bump. If it stops crashing, the DEFAULT changes and the guard goes.
    assert_equal 4, TestParallelism.worker_count(
      { "PARALLEL_WORKERS" => "4", "PARALLEL_WORKERS_ALLOW_UNSAFE" => "1" }
    )
  end

  test "the override is exact — a near-miss value does not unlock it" do
    # A guard you can trip by typo is not a guard.
    out, err = capture_io do
      assert_equal 1, TestParallelism.worker_count(
        { "PARALLEL_WORKERS" => "4", "PARALLEL_WORKERS_ALLOW_UNSAFE" => "true" }
      )
    end
    refute_empty "#{out}#{err}"
  end

  test "a blank or non-numeric PARALLEL_WORKERS is ignored, not crashed on" do
    assert_equal 1, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "" })
    assert_equal :number_of_processors, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "auto", "CI" => "1" })
  end
end
