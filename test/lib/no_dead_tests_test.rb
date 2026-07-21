# frozen_string_literal: true

require "test_helper"

# A test method defined below a bare `private` is NEVER RUN. Minitest collects only
# PUBLIC `test_*` methods, so such a test is silently skipped — the file still reports
# green, the run count still goes up by the tests that DID run, and nothing anywhere
# says the others are missing.
#
#   bin/rails test test/lib/no_dead_tests_test.rb   (or any full-suite run)
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
#
# HOW THIS CHECK WORKS — and why it was rewritten (PR #777 / the nesting bug).
#
# The first three versions of this guard were a TEXT SCANNER: read each `*_test.rb`
# as a string and flip a single `visibility` flag on any bare `private` line. It kept
# being wrong in a new way each time, and every fix patched the one spelling that had
# just bitten:
#
#   1. bare `private` at a test class's top level          — the real PR #549 bug.
#   2. `private` inside a HEREDOC body (a STRING, not a     — falsely stranded two live
#      keyword; a fixture that quotes Ruby source)            tests; "fixed" by blanking
#                                                              heredoc bodies before scanning.
#   3. `private` inside a NESTED class or module            — a nested Stub's `private`
#      (Ruby scopes default visibility to the enclosing       poisoned every `def` to end
#      body; it does NOT leak to the outer class)             of file, so PR #607's public
#                                                              integration test read as dead
#                                                              and its correct PR was blocked
#                                                              at review gate-zero.
#
# Three spellings of ONE disease: the scanner asserted a REMEMBERED EXAMPLE of what a
# dead test looked like (a flat file, no strings, no nesting) instead of the INVARIANT
# it actually cares about — *is this test method collected by Minitest?* Text can never
# answer that; only the runtime can. So the guard now ASKS THE RUNTIME.
#
# THE INVARIANT: every `test_*` method DEFINED on a loaded Minitest::Test subclass must
# be PUBLIC, because Minitest collects public `test_*` methods only (see
# Minitest::Test.runnable_methods). A `test_*` that exists on the class as a PRIVATE or
# PROTECTED instance method is defined-but-uncollected — dead. `#dead_test_methods`
# asks exactly that, by reflection. It reads no source text, so it is immune to
# nesting, heredocs, comments, string literals, `__END__` data, and every future
# spelling — Ruby has already applied its real visibility rules by the time the classes
# are loaded, and we simply read the result.
#
# COMPLETE UNDER A FULL-SUITE RUN. Reflection sees a class only once it is loaded. A
# full run — CI, `bin/rails test`, `bin/full-suite-check` — requires every `*_test.rb`
# before running any test, so by the time this guard executes, EVERY test class is
# present in `Minitest::Runnable.runnables` and the sweep is exhaustive. (Running this
# one file in isolation only reflects over what that invocation loaded; it cannot
# false-RED, it simply sees less. The gate that matters — CI — runs the whole suite.)
#
# NOTHING IS EXEMPT — not even this file. The old scanner had to SKIP itself, because it
# carried a permanently-stranded dead test as a fixture and would have flagged it ("a
# checker exempt from itself cannot see its own disease"). Reflection needs no such
# fixture: this class's own tests are all public, so the sweep passes over it honestly,
# and the detector's power to catch a real dead test is RE-PROVEN every run by the
# mutation tests below (which build throwaway classes, never registered as runnables).
class NoDeadTestsTest < Minitest::Test
  # The invariant, by reflection: the `test_*` methods DEFINED directly on `klass`
  # (the `false` — inherited base-class methods are not this class's concern) that
  # Ruby has placed in private or protected visibility. Minitest will not collect
  # them, so each one is a dead test. Returns their names, sorted, as strings.
  def dead_test_methods(klass)
    (klass.private_instance_methods(false) + klass.protected_instance_methods(false))
      .map(&:to_s)
      .grep(/\Atest_/)
      .sort
  end

  # THE SWEEP. Ask every loaded Minitest::Test subclass the invariant question.
  def test_unit_no_defined_test_method_is_left_uncollected_by_minitest
    dead = Minitest::Runnable.runnables.flat_map do |klass|
      next [] unless klass.is_a?(Class) && klass < Minitest::Test

      dead_test_methods(klass).map { |name| "#{klass}##{name}" }
    end.sort

    assert_empty dead,
                 "These `test_*` methods are defined but NOT public, so Minitest never runs them " \
                 "(it collects public test_* methods only):\n  " + dead.join("\n  ") +
                 "\n\nA `test_*` method lands here when it sits below a bare `private`/`protected` at its " \
                 "class's top level. Move it above that keyword, or re-open visibility with `public` first. " \
                 "A test that cannot fail is not evidence — and the suite will keep reporting green."
  end

  # MUTATION, DIRECTION 1 — the detector MUST catch a genuinely dead test. If someone
  # weakens `dead_test_methods` so it stops seeing private test methods, this goes RED.
  # The fixtures are plain classes built at runtime: they are NOT Minitest::Test
  # subclasses, so they never register as runnables and never themselves run — they
  # exist only to be interrogated.
  def test_unit_the_detector_catches_a_genuinely_private_test
    dead = Class.new
    dead.class_eval(<<~SRC, __FILE__, __LINE__ + 1)
      def test_this_one_runs; assert true; end
      private
      def helper = 1
      def test_this_one_never_runs; assert false; end
    SRC

    assert_equal ["test_this_one_never_runs"], dead_test_methods(dead),
                 "a test_* method below a bare `private` is uncollected and must be flagged"
  end

  # MUTATION, DIRECTION 2 — a test re-opened with `public` is collected and must NOT be
  # flagged. The fix has to read as fixed.
  def test_unit_a_test_reopened_with_public_is_not_flagged
    revived = Class.new
    revived.class_eval(<<~SRC, __FILE__, __LINE__ + 1)
      def test_this_one_runs; assert true; end
      private
      def helper = 1
      public
      def test_this_one_runs_again; assert true; end
    SRC

    assert_empty dead_test_methods(revived),
                 "a test re-opened with `public` is collected, and must not be flagged"
  end

  # REGRESSION — PR #607. A `private` inside a NESTED class scopes to that class; Ruby
  # does not leak it to the enclosing class, so the outer test stays public and
  # collected. The text scanner read the nested `private` as poisoning the rest of the
  # file and stranded this exact public integration test, blocking a correct PR. The
  # class here is built by REAL Ruby (`class_eval` of a literal source), so Ruby's own
  # visibility rules produce the answer — the fixture cannot lie about the semantics.
  def test_unit_a_private_inside_a_nested_class_does_not_strand_the_enclosing_test
    with_nested_stub = Class.new
    with_nested_stub.class_eval(<<~SRC, __FILE__, __LINE__ + 1)
      class StubBoard
        def enqueue(job); job; end

        private

        def guard; end
        def close; end
      end

      def test_integration_a_headless_renewer_holds_the_lease_then_frees_it_when_its_anchor_dies
        assert true
      end
    SRC

    assert_empty dead_test_methods(with_nested_stub),
                 "the nested StubBoard's `private` scopes to StubBoard; the enclosing test is public " \
                 "and IS collected, so it must not be reported dead (PR #607's false positive)"

    # …and the fix must not have BLINDED the detector: a REAL bare `private` at the
    # OUTER class level, after the same nested stub, still strands the test below it.
    really_dead = Class.new
    really_dead.class_eval(<<~SRC, __FILE__, __LINE__ + 1)
      class StubBoard
        def enqueue(job); job; end

        private

        def guard; end
      end

      private

      def test_integration_now_actually_stranded
        assert true
      end
    SRC

    assert_equal ["test_integration_now_actually_stranded"], dead_test_methods(really_dead),
                 "a genuine bare `private` at the outer class level still strands the test below it"
  end

  # REGRESSION — a `private` inside a heredoc (or any string / method body) is not a
  # visibility keyword. Reflection never reads method bodies, so this is immune by
  # construction; the test documents that the earlier false positive is gone. The real
  # class defines a test whose BODY quotes Ruby source containing a bare `private`.
  def test_unit_a_private_inside_a_heredoc_is_a_string_not_a_visibility_keyword
    with_heredoc = Class.new
    with_heredoc.class_eval(<<~'SRC', __FILE__, __LINE__ + 1)
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
    SRC

    assert_empty dead_test_methods(with_heredoc),
                 "the `private` lives inside a string; both tests are public and collected, so neither " \
                 "may be reported dead"
  end
end
