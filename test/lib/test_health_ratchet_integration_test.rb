# frozen_string_literal: true

# [integration] Does the ratchet actually FAIL A BUILD? Standalone (no Rails):
#   ruby -Itest test/lib/test_health_ratchet_integration_test.rb
#
# The unit tests next door prove the detector flags the right shapes and that the
# counts match the contract. That is not the same claim as this one. A guard earns its
# place by making CI go red, and an assertion being false is only half of that — the
# file has to load, the YAML has to parse, the comparison has to run, and the process
# has to exit non-zero. This drives the REAL guard file as a subprocess against a
# throwaway tree and watches the exit status.
#
# HERMETIC ON PURPOSE. TEST_HEALTH_ROOT points the guard at a tmpdir containing its own
# config/test_health.yml and its own test/, so nothing here writes into the repo it is
# testing. An earlier seam in this codebase learned that the hard way: a probe file
# dropped into a real directory and cleaned up afterwards still failed under CI's
# parallel workers, because another process saw it mid-flight.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class TestHealthRatchetIntegrationTest < Minitest::Test
  GUARD = File.expand_path("test_health_ratchet_test.rb", __dir__)
  ROOT  = File.expand_path("../..", __dir__)

  CLEAN_TEST = <<~RB
    require "minitest/autorun"
    class HonestTest < Minitest::Test
      def test_it_asserts_something
        assert_equal 2, 1 + 1
      end
    end
  RB

  ASSERTS_NOTHING = <<~RB
    require "minitest/autorun"
    class HollowTest < Minitest::Test
      def test_it_asserts_nothing
        [1, 2, 3].map { |i| i * 2 }
      end
    end
  RB

  def test_a_clean_tree_passes_the_guard
    out, status = run_guard(tests: { "honest_test.rb" => CLEAN_TEST }, skips: 0, assertion_free: 0)

    assert status.success?, "a suite that matches its ratchet must pass:\n#{out}"
  end

  def test_a_planted_assertion_free_test_fails_the_build
    out, status = run_guard(tests: { "hollow_test.rb" => ASSERTS_NOTHING }, skips: 0, assertion_free: 0)

    refute status.success?, "a test that asserts nothing must FAIL the build, not merely be noticed"
    assert_match(/assertion-free test/, out)
    assert_match(/hollow_test\.rb/, out, "the refusal must NAME the offending file, or it is not actionable")
  end

  def test_an_unrecorded_skip_fails_the_build
    skipped = <<~RB
      require "minitest/autorun"
      class SkippedTest < Minitest::Test
        def test_switched_off
          skip "later"
          assert true
        end
      end
    RB
    out, status = run_guard(tests: { "skipped_test.rb" => skipped }, skips: 0, assertion_free: 0)

    refute status.success?, "a skip added without updating the ratchet must fail the build"
    assert_match(/skip call site/, out)
  end

  # THE CONTROL FOR THE TWO ABOVE. Declaring the skip in the ratchet makes the same
  # tree pass — so the guard is reading the contract, not simply refusing anything
  # that contains the word `skip`.
  def test_a_declared_skip_passes
    skipped = <<~RB
      require "minitest/autorun"
      class SkippedTest < Minitest::Test
        def test_switched_off
          skip "declared in the ratchet"
          assert true
        end
      end
    RB
    out, status = run_guard(tests: { "skipped_test.rb" => skipped }, skips: 1, assertion_free: 0)

    assert status.success?, "a skip the ratchet declares is not a regression:\n#{out}"
  end

  def test_the_repo_itself_is_never_written_to
    before = Dir.glob(File.join(ROOT, "test", "**", "*_test.rb")).size
    run_guard(tests: { "hollow_test.rb" => ASSERTS_NOTHING }, skips: 0, assertion_free: 0)

    assert_equal before, Dir.glob(File.join(ROOT, "test", "**", "*_test.rb")).size,
                 "the integration test must not add or remove files in the real suite"
  end

  private

  # Build a throwaway tree, point the REAL guard at it, return [output, status].
  def run_guard(tests:, skips:, assertion_free:)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "test", "lib"))
      # frozen_size is declared (empty) because the guard asserts the contract and the
      # guard itself never drift — a key the guard reads but the contract omits fails
      # on arrival, which is exactly what that assertion is for.
      File.write(File.join(root, "config", "test_health.yml"),
                 "---\nskips: #{skips}\nassertion_free: #{assertion_free}\nfrozen_size: {}\n")
      tests.each { |name, body| File.write(File.join(root, "test", "lib", name), body) }

      Open3.capture2e({ "TEST_HEALTH_ROOT" => root }, RbConfig.ruby, "-I#{File.join(ROOT, "test")}", GUARD)
    end
  end
end
