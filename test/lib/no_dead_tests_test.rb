# frozen_string_literal: true

# A test method defined below a bare `private` is NEVER RUN. Minitest collects only
# PUBLIC `test_*` methods, so such a test is silently skipped — the file still reports
# green, the run count still goes up by the tests that DID run, and nothing anywhere
# says the others are missing.
#
#   ruby -Itest test/lib/no_dead_tests_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# FOUND THE HARD WAY (PR #549). Fourteen tests across three files were dead:
#
#   * atomic_event_cli_test  — including the TWO sandbox integration tests that the
#     PR's own checks_run cited as proof an unpinned spawn aborts. The reviewer read
#     that evidence and believed it. It had never executed.
#   * agent_worktree_test    — and a `-n /registry/` filter run still reported "2 runs,
#     green", because it matched two OTHER tests whose names contain "registry". A
#     filtered green is not proof that YOUR test ran.
#   * atomic_capture_hook_test — eight, including the hook's SECRET-REDACTION tests. A
#     redaction test that never runs is worse than no test, because the suite reports
#     the behaviour as covered.
#
# All fourteen passed once made public — they were correct tests, silently uncollected.
# That is the danger: nothing fails, so nothing tells you. The suite cannot notice a
# test that is not there, so the check has to be made against the SOURCE.
class NoDeadTestsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_unit_no_test_method_is_defined_below_a_private_keyword
    dead = Dir.glob(File.join(ROOT, "test", "**", "*_test.rb")).sort.flat_map do |path|
      next [] if path == __FILE__ # this file carries a DELIBERATE stranded test, as a fixture

      dead_tests_in(File.read(path)).map { |line, name| "#{path.delete_prefix("#{ROOT}/")}:#{line} #{name}" }
    end

    assert_empty dead,
                 "These test methods are defined below a bare `private` and are NEVER RUN by Minitest " \
                 "(it collects public test_* methods only):\n  " + dead.join("\n  ") +
                 "\n\nMove them above the `private`, or re-open visibility with `public` before them. " \
                 "A test that cannot fail is not evidence — and the suite will keep reporting green."
    end

  # Track DEFAULT method visibility the way Ruby does: a bare `private` / `public` /
  # `protected` on its own line flips it for every `def` that follows. (`private :foo`
  # and `private def foo` do not, and are correctly ignored — they take an argument.)
  def dead_tests_in(src)
    visibility = :public

    src.lines.each_with_index.filter_map do |line, i|
      case line
      when /^\s*private\s*$/ then visibility = :private
      when /^\s*protected\s*$/ then visibility = :protected
      when /^\s*public\s*$/ then visibility = :public
      when /^\s*def\s+(test_\w+)/
        next [i + 1, ::Regexp.last_match(1)] unless visibility == :public
      end
      nil
    end
  end

  # The sweep must be able to FAIL — a green run here is meaningless if the detector
  # cannot see the bug it exists for. Drive it with the exact shape found in PR #549.
  def test_unit_the_sweep_detects_a_test_stranded_below_private
    stranded = <<~RUBY
      class Example < Minitest::Test
        def test_this_one_runs
          assert true
        end

        private

        def helper = 1

        def test_this_one_never_runs
          assert false
        end
      end
    RUBY

    found = dead_tests_in(stranded)
    assert_equal 1, found.size, "the sweep must flag exactly the stranded test (got #{found.inspect})"
    assert_equal "test_this_one_never_runs", found.first.last

    # …and must NOT flag one that `public` correctly re-opens — the fix has to read as fixed.
    revived = stranded.sub("def test_this_one_never_runs", "public\n\n  def test_this_one_never_runs")
    assert_empty dead_tests_in(revived), "a test re-opened with `public` is collected, and must not be flagged"
  end
end
