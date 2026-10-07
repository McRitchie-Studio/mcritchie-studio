# frozen_string_literal: true

# [integration] Does the ratchet actually FAIL A BUILD? Standalone (no Rails):
#   ruby -Itest test/lib/test_health_ratchet_integration_test.rb
#
# The unit tests next door prove the detector flags the right shapes. This drives the
# REAL guard file as a subprocess against a throwaway git tree and watches the exit
# status: the file has to load, the YAML has to parse, the merge base has to be read,
# the comparison has to run, and the process has to exit non-zero.
#
# HERMETIC ON PURPOSE. TEST_HEALTH_ROOT points the guard at a tmpdir holding its own
# git repository, config/test_health.yml and test/; TEST_HEALTH_BASE names the commit
# that stands in for the merge base. Nothing here writes into the repo under test.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class TestHealthRatchetIntegrationTest < Minitest::Test
  GUARD = File.expand_path("test_health_ratchet_test.rb", __dir__)
  ROOT  = File.expand_path("../..", __dir__)
  HOTSPOT = "test/lib/hotspot_test.rb"

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

  SKIPPED = <<~RB
    require "minitest/autorun"
    class SkippedTest < Minitest::Test
      def test_switched_off
        skip "later"
        assert true
      end
    end
  RB

  def test_a_clean_tree_passes_the_guard
    out, status = run_guard(base: { "honest_test.rb" => CLEAN_TEST })

    assert status.success?, "a suite that matches its ratchet must pass:\n#{out}"
  end

  def test_a_planted_assertion_free_test_fails_the_build
    out, status = run_guard(base: {}, now: { "hollow_test.rb" => ASSERTS_NOTHING })

    refute status.success?, "a test that asserts nothing must FAIL the build, not merely be noticed"
    assert_match(/assertion-free test/, out)
    assert_match(/hollow_test\.rb/, out, "the refusal must NAME the offending file, or it is not actionable")
  end

  def test_a_skip_added_since_the_merge_base_fails_the_build
    out, status = run_guard(base: { "honest_test.rb" => CLEAN_TEST }, now: { "skipped_test.rb" => SKIPPED })

    refute status.success?, "a skip added since the merge base must fail the build"
    assert_match(/skip call site/, out)
  end

  # THE CONTROLS. The count is read from the merge base, not stored: a skip the base
  # already carried passes, and removing one passes with no edit anywhere.
  def test_a_skip_the_merge_base_already_carried_passes
    out, status = run_guard(base: { "skipped_test.rb" => SKIPPED })

    assert status.success?, "a skip present at the merge base is not a regression:\n#{out}"
  end

  def test_removing_a_skip_passes_with_no_edit
    out, status = run_guard(base: { "skipped_test.rb" => SKIPPED }, now: { "skipped_test.rb" => CLEAN_TEST })

    assert status.success?, "lowering the skip count needs no edit to any file:\n#{out}"
  end

  def test_a_frozen_file_that_grew_fails_the_build
    out, status = run_guard(base: { "hotspot_test.rb" => CLEAN_TEST },
                            now: { "hotspot_test.rb" => CLEAN_TEST + "# one more line\n" })

    refute status.success?, "a frozen hotspot that grew past its merge-base size must fail the build"
    assert_match(/hotspot_test\.rb is \d+ lines, \d+ at the merge base/, out)
  end

  def test_a_frozen_file_that_shrank_or_is_new_passes
    shrunk = CLEAN_TEST.lines.first(5).join
    out, status = run_guard(base: { "hotspot_test.rb" => CLEAN_TEST }, now: { "hotspot_test.rb" => shrunk })
    assert status.success?, "shrinking a frozen file is always allowed:\n#{out}"

    out, status = run_guard(base: {}, now: { "hotspot_test.rb" => CLEAN_TEST })
    assert status.success?, "a frozen path absent at the merge base has no size to exceed:\n#{out}"
  end

  # FAIL CLOSED. A ratchet that cannot see its baseline cannot certify anything.
  def test_an_unreadable_merge_base_fails_the_build
    out, status = run_guard(base: { "honest_test.rb" => CLEAN_TEST }, base_ref: "no-such-ref")

    refute status.success?, "a missing merge base must be RED, never a pass"
    assert_match(/merge base/, out)
  end

  def test_the_repo_itself_is_never_written_to
    before = Dir.glob(File.join(ROOT, "test", "**", "*_test.rb")).size
    run_guard(base: {}, now: { "hollow_test.rb" => ASSERTS_NOTHING })

    assert_equal before, Dir.glob(File.join(ROOT, "test", "**", "*_test.rb")).size,
                 "the integration test must not add or remove files in the real suite"
  end

  private

  # Commit `base` (test/lib files) as the merge base, then write `now` over the working
  # tree, point the REAL guard at it, and return [output, status].
  def run_guard(base:, now: {}, base_ref: nil)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "test", "lib"))
      File.write(File.join(root, "config", "test_health.yml"),
                 "---\nassertion_free: 0\nfrozen:\n  - #{HOTSPOT}\n")
      base.each { |name, body| File.write(File.join(root, "test", "lib", name), body) }
      git(root, "init", "-q")
      git(root, "add", "-A")
      git(root, "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-q", "--allow-empty", "-m", "base")
      sha = git(root, "rev-parse", "HEAD").strip
      now.each { |name, body| File.write(File.join(root, "test", "lib", name), body) }

      env = { "TEST_HEALTH_ROOT" => root, "TEST_HEALTH_BASE" => base_ref || sha }
      Open3.capture2e(env, RbConfig.ruby, "-I#{File.join(ROOT, "test")}", GUARD)
    end
  end

  def git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end
end
