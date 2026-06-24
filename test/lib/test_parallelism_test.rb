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

  test "PARALLEL_WORKERS overrides both local and CI" do
    assert_equal 4, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "4" })
    assert_equal 1, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "1", "CI" => "true" })
  end

  test "a blank or non-numeric PARALLEL_WORKERS is ignored, not crashed on" do
    assert_equal 1, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "" })
    assert_equal :number_of_processors, TestParallelism.worker_count({ "PARALLEL_WORKERS" => "auto", "CI" => "1" })
  end
end
