# frozen_string_literal: true

require "test_helper"

# The DETERMINISTIC reproduction of the leak that reddened
# test/integration/test_database_hermeticity_test.rb in someone else's diff, three
# times, and only sometimes.
#
# THE ORIGINAL FAILURE WAS A LOTTERY. A non-transactional test committed one
# `task_events` row and never removed it; the hermeticity invariant went red only
# when minitest happened to shuffle it AFTER that test, in the same process. Re-run
# the same SHA and it passed. That is why the bug survived three sessions: nothing
# reproduced it on demand.
#
# SO THE ORDER IS PINNED HERE INSTEAD OF WISHED FOR. Each test below RUNS a real,
# purpose-built test case in-process — through the actual Minitest lifecycle, with
# the real hooks installed — and then inspects its result. Ordering stops being the
# suite's business: the polluter and the check are one call apart.
#
# The receipt is POSITIVE. "No rows appeared" would also pass if the write simply
# never happened, so these assert that the guard FIRED and what it SAID, and the
# mutation twin (the same case, cleaning up properly) asserts it stays quiet — both
# directions, so neither a dead guard nor a guard that fails everything can pass.
class TestDatabaseLeakGuardTest < ActiveSupport::TestCase
  SLUG = "leak-guard-probe-subject"

  # A REAL non-transactional test case, built ANONYMOUSLY on purpose: minitest
  # materializes its runnable list once, at run start, so a class created here is
  # never collected by the sweep. That is what lets a deliberately LEAKY test live
  # inside a suite whose whole point is failing on leaks.
  #
  # Fixtures are turned off for it (`fixture_table_names = []`) — it needs none, and
  # a non-transactional case otherwise re-inserts every fixture on setup, which is
  # pure cost here.
  def probe_case(&body)
    Class.new(ActiveSupport::TestCase) do
      self.use_transactional_tests = false
      self.fixture_table_names = []

      def self.name = "LeakGuardProbeCase"

      define_method(:test_probe, &body)
    end
  end

  # Run one and hand back its Minitest::Result (`#failures` is the receipt).
  def run_probe(&body)
    probe_case(&body).new(:test_probe).run
  end

  # The bug, exactly as it was written: create a Task (whose `after_create
  # :record_genesis_event` writes a TaskEvent), then clean up with `delete_all`,
  # which skips `dependent: :destroy` and leaves the event behind. Returns the
  # orphan count so a caller can assert the leak really happened — a probe that
  # silently wrote nothing would make every "the guard fired" assertion vacuous.
  #
  # A class method so the probe cases (a different object, running their own
  # lifecycle) and the unit tests below drive the SAME shape from one definition.
  def self.leak_a_task_event!
    Task.create!(title: "Leak Guard Probe", slug: SLUG, stage: "submitted")
    Task.where(slug: SLUG).delete_all
    TaskEvent.where(task_slug: SLUG).count
  end

  def unfixtured_rows
    connection = ActiveRecord::Base.connection
    TestDatabasePurge.row_counts(TestDatabasePurge.unfixtured_tables(connection), connection)
  end

  # ── the receipt ────────────────────────────────────────────────────────────

  test "[integration] a test that orphans a row FAILS, and the failure names the table" do
    result = run_probe do
      assert_equal 1, TestDatabaseLeakGuardTest.leak_a_task_event!,
                   "the probe must really orphan an event, or the guard has nothing to catch"
    end

    assert_equal 1, result.failures.size, "the leaky test must be failed by the guard, exactly once"
    failure = result.failures.first
    assert_kind_of Minitest::Assertion, failure,
                   "it must be reported as a FAILURE (a raised error would read as a broken test)"
    assert_match(/LEAKED ROWS/, failure.message)
    assert_match(/task_events: 1 row\(s\)/, failure.message,
                 "the message must name the table and the count — that is the whole diagnosis")
    assert_match(/dependent: :destroy/, failure.message,
                 "and it must name the cause that produced it, so the fix is obvious")
  end

  test "[integration] the SAME case passes once it cleans up what the callbacks wrote" do
    # The mutation twin, and the fix applied to ReviewPendingActionSettleRaceTest:
    # delete the children explicitly. If this went red the guard would be a blanket
    # failure rather than a leak detector.
    result = run_probe do
      Task.create!(title: "Leak Guard Probe", slug: SLUG, stage: "submitted")
      TaskEvent.where(task_slug: SLUG).delete_all
      Task.where(slug: SLUG).delete_all
      assert_equal 0, TaskEvent.where(task_slug: SLUG).count
    end

    assert_empty result.failures, "a test that cleans up completely must be left alone"
  end

  test "[integration] a leak is CONTAINED, so the NEXT test still starts empty" do
    # This is the half that makes the hermeticity invariant order-independent: the
    # leak is truncated at the polluter's teardown, so no later test can inherit it.
    # Asserted against the un-fixtured tables as a whole, not against task_events,
    # for the same reason the invariant is written that way.
    run_probe { assert_equal 1, TestDatabaseLeakGuardTest.leak_a_task_event! }

    assert_empty unfixtured_rows,
                 "the guard must clean up after the test it failed — otherwise the next test pays too"
  end

  test "[integration] the bare-minitest lane is covered by its own hook" do
    # test/lib and test/commands are bare `minitest/autorun` files: they never inherit
    # from ActiveSupport::TestCase, so the Rails hook cannot see them. Under the
    # `bin/rails test` sweep they load alongside Rails and can reach this same
    # database, which is why there is a second hook on Minitest::Test. Proven here
    # rather than asserted — an untested hook is a hook nobody knows is installed.
    bare = Class.new(Minitest::Test) do
      def self.name = "LeakGuardBareProbeCase"

      define_method(:test_probe) do
        assert_equal 1, TestDatabaseLeakGuardTest.leak_a_task_event!
      end
    end

    result = bare.new(:test_probe).run

    assert_equal 1, result.failures.size, "a bare minitest test must be held to the same rule"
    assert_match(/task_events: 1 row\(s\)/, result.failures.first.message)
  end

  test "[integration] an already-failing test is contained but not double-reported" do
    # A test that blew up mid-way never got to clean up, and burying its real failure
    # under a leak report would make the diagnosis worse, not better.
    result = run_probe do
      TestDatabaseLeakGuardTest.leak_a_task_event!
      flunk "the real failure"
    end

    assert_equal 1, result.failures.size, "the original failure must stand alone"
    assert_match(/the real failure/, result.failures.first.message)
    refute_match(/LEAKED ROWS/, result.failures.first.message)
    assert_empty unfixtured_rows, "the rows are still swept — containment is unconditional"
  end

  # ── the sweep itself ───────────────────────────────────────────────────────

  test "[unit] sweep! reports every leaked table with its count, then empties it" do
    assert_equal 1, TestDatabaseLeakGuardTest.leak_a_task_event!

    counts = TestDatabaseLeakGuard.sweep!(ActiveRecord::Base.connection)

    assert_equal({ "task_events" => 1 }, counts, "the counts are the report the failure prints")
    assert_empty unfixtured_rows, "and the tables are empty afterwards"
  end

  test "[unit] sweep! is silent on a clean database" do
    assert_empty TestDatabaseLeakGuard.sweep!(ActiveRecord::Base.connection),
                 "a clean database must produce no report — a guard that cries wolf gets disabled"
  end

  test "[unit] sweep! never touches a FIXTURED table" do
    # The blast radius has to stop at the fixtures: truncating them would empty the
    # world every other test in this process depends on. `tasks` has a fixture, so a
    # row left there is Rails' problem to clean (it reloads fixtures), never ours.
    before = Task.count
    assert_operator before, :>, 0, "the tasks fixture must exist for this to mean anything"
    Task.create!(title: "Leak Guard Fixtured Table", slug: SLUG, stage: "submitted")

    TestDatabaseLeakGuard.sweep!(ActiveRecord::Base.connection)

    assert_equal before + 1, Task.count, "a fixtured table must survive the sweep untouched"
  end

  test "[unit] the guard watches the same tables the standing invariant asserts" do
    # One list, two consumers. If these ever diverge, one of them is guarding a
    # table the other ignores — which is how the original hole stayed open.
    connection = ActiveRecord::Base.connection

    assert_equal TestDatabasePurge.unfixtured_tables(connection),
                 TestDatabaseLeakGuard.unfixtured_tables(connection)
    assert_includes TestDatabaseLeakGuard.unfixtured_tables(connection), "task_events"
  end
end
