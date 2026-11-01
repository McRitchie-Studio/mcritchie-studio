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

  LONG_COMMENT = (1..9).map { |n| "# line #{n}\n" }.join

  def test_a_new_long_comment_block_fails_the_build
    out, status = run_guard(base: { "honest_test.rb" => CLEAN_TEST },
                            now: { "honest_test.rb" => LONG_COMMENT + CLEAN_TEST })

    refute status.success?, "a new comment block over the cap must fail the build"
    assert_match(/honest_test\.rb:1 is a 9-line comment block/, out)
  end

  def test_a_grandfathered_long_comment_block_passes
    out, status = run_guard(base: { "honest_test.rb" => LONG_COMMENT + CLEAN_TEST })

    assert status.success?, "a block the merge base held is grandfathered:\n#{out}"
  end

  # REPORT-ONLY, proven on the real exit status: over the ceiling is printed, not red.
  def test_over_the_ceiling_reports_without_failing_until_enforced
    tree = { base: { "honest_test.rb" => "\n" }, now: { "honest_test.rb" => CLEAN_TEST } }

    out, status = run_guard(**tree, budget: "enforce: false\n  ceiling: 1")
    assert status.success?, "report-only must not redden a PR:\n#{out}"
    assert_match(/::warning title=test line budget::\d+ test lines \(ceiling 1, over by \d+\)/, out)

    out, status = run_guard(**tree, budget: "enforce: true\n  ceiling: 1")
    refute status.success?, "an enforced ceiling must fail a PR that adds lines"
  end

  def test_an_enforced_ceiling_lets_a_cut_through
    out, status = run_guard(base: { "honest_test.rb" => CLEAN_TEST }, now: { "honest_test.rb" => "\n\n" },
                            budget: "enforce: true\n  ceiling: 1", now_budget: nil)

    assert status.success?, "the PR that cuts lines must pass, or nothing can clear the ceiling:\n#{out}"
  end

  def test_raising_the_ceiling_fails_the_build
    out, status = run_guard(base: {}, budget: "enforce: false\n  ceiling: 100",
                            now_budget: "enforce: false\n  ceiling: 101")

    refute status.success?, "the ceiling may only fall"
    assert_match(/ceiling rose/, out)
  end

  # A sibling repo adopts the check with no config at all: real script, real exit code.
  def test_the_shared_script_runs_on_a_repo_with_no_config
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "test", "a_test.rb"), CLEAN_TEST)
      sha = commit_all(root)
      env = { "TEST_HEALTH_BASE" => sha }

      out, status = Open3.capture2e(env, File.join(ROOT, "bin", "test-health"), "--root", root)
      assert status.success?, out
      assert_match(/\A6 test lines \(no ceiling set\)/, out)

      File.write(File.join(root, "test", "a_test.rb"), LONG_COMMENT + CLEAN_TEST)
      out, status = Open3.capture2e(env, File.join(ROOT, "bin", "test-health"), "--root", root)
      refute status.success?, out
      assert_match(/FAIL test\/a_test\.rb:1/, out)
    end
  end

  def test_the_repo_itself_is_never_written_to
    before = Dir.glob(File.join(ROOT, "test", "**", "*_test.rb")).size
    run_guard(base: {}, now: { "hollow_test.rb" => ASSERTS_NOTHING })

    assert_equal before, Dir.glob(File.join(ROOT, "test", "**", "*_test.rb")).size,
                 "the integration test must not add or remove files in the real suite"
  end

  private

  # Commit `base` (test/lib files) as the merge base, then write `now` over the working
  # tree, point the REAL guard at it, and return [output, status]. `budget` is the
  # line_budget body at the base; `now_budget` replaces it in the working tree.
  def run_guard(base:, now: {}, base_ref: nil, budget: "enforce: false", now_budget: budget)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test", "lib"))
      write_config(root, budget)
      base.each { |name, body| File.write(File.join(root, "test", "lib", name), body) }
      sha = commit_all(root)
      now.each { |name, body| File.write(File.join(root, "test", "lib", name), body) }
      write_config(root, now_budget) if now_budget

      env = { "TEST_HEALTH_ROOT" => root, "TEST_HEALTH_BASE" => base_ref || sha }
      Open3.capture2e(env, RbConfig.ruby, "-I#{File.join(ROOT, "test")}", GUARD)
    end
  end

  def write_config(root, budget)
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config", "test_health.yml"),
               "---\nassertion_free: 0\ncomment_blocks:\n  max_lines: 8\nline_budget:\n  #{budget}\n" \
               "frozen:\n  - #{HOTSPOT}\n")
  end

  def commit_all(root)
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-q", "--allow-empty", "-m", "base")
    git(root, "rev-parse", "HEAD").strip
  end

  def git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end
end
