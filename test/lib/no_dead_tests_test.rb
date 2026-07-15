# frozen_string_literal: true

# A test method defined below a bare `private` is NEVER RUN. Minitest collects only
# PUBLIC `test_*` methods, so such a test is silently skipped — the file still reports
# green, the run count still goes up by the tests that DID run, and nothing anywhere
# says the others are missing.
#
#   bin/rails test test/lib/no_dead_tests_test.rb
#
# (NOT `ruby -Itest …` — this file does not require minitest/autorun, so that dies with
# "uninitialized constant Minitest". A dead-test detector shipping a command that never
# runs would be the joke writing itself; PR #549's review caught it.)
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

  # Blank out HEREDOC BODIES before reading visibility. A `private` inside a STRING is not
  # a visibility keyword — but this scanner is pure text, and it read one as such: the
  # moment a test fixtured Ruby source containing a bare `private` (which
  # state_store_containment_test.rb now does, to prove its own visibility analyser),
  # every test after that fixture was falsely reported dead.
  #
  # The bug hid because the sweep SKIPS this file (its own stranded fixture would trip
  # it), and this file is full of `private`-bearing heredocs. A checker exempt from
  # itself cannot see its own disease.
  #
  # Blanked, not deleted, so reported line numbers still point at the real file. And note
  # the DIRECTION of error: stripping too much would hide a genuinely dead test, so only
  # the body between a `<<~ID` opener and its EXACT terminator line is removed — never a
  # line this scanner is not certain is inside a string.
  def strip_heredocs(src)
    terminator = nil

    src.lines.map do |line|
      if terminator
        terminator = nil if line =~ /^\s*#{Regexp.escape(terminator)}\s*$/
        "\n"
      else
        m = line.match(/<<[~-]?(["']?)([A-Z_][A-Z0-9_]*)\1/)
        terminator = m[2] if m
        line
      end
    end.join
  end

  # Track DEFAULT method visibility the way Ruby does: a bare `private` / `public` /
  # `protected` on its own line flips it for every `def` that follows. (`private :foo`
  # and `private def foo` do not, and are correctly ignored — they take an argument.)
  def dead_tests_in(src)
    visibility = :public

    strip_heredocs(src).lines.each_with_index.filter_map do |line, i|
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

  # A `private` inside a heredoc is a STRING. Ruby does not flip visibility on it, and
  # neither may this sweep — it did, and falsely stranded two live tests.
  #
  # The second half is the part that matters: a fix that made the false positive go away
  # by making the scanner blinder would be a WEAKENING, and it would pass the first half
  # happily. So the same fixture is mutated to strand a test FOR REAL, after the heredoc,
  # and the sweep must still catch it. That is the difference between "green" and "works".
  def test_unit_a_private_inside_a_heredoc_is_a_string_not_a_visibility_keyword
    src = <<~OUTER
      class Example < Minitest::Test
        def test_first
          fixture = <<~INNER
            class Thing
              private

              def hidden; end
            end
          INNER
          assert fixture
        end

        def test_after_the_heredoc
          assert true
        end
      end
    OUTER

    assert_empty dead_tests_in(src),
                 "the `private` lives inside a string. Ruby collects test_after_the_heredoc, so the sweep " \
                 "must not report it dead — a false RED here gets the whole detector deleted."

    really_dead = src.sub("  def test_after_the_heredoc", "  private\n\n  def test_after_the_heredoc")
    found = dead_tests_in(really_dead)
    assert_equal ["test_after_the_heredoc"], found.map(&:last),
                 "and the heredoc fix must not have BLINDED the sweep: a REAL bare `private` after the same " \
                 "heredoc still strands the test below it"
  end
end
