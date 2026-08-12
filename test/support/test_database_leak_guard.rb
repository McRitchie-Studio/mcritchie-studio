# frozen_string_literal: true

require_relative "test_database_purge"

# TestDatabaseLeakGuard — keep the minitest database hermetic DURING the run, and
# blame the test that dirtied it.
#
# THE BUG THIS EXISTS TO KILL (measured 2026-08-12, three sessions taxed by it):
# `TestDatabasePurge.purge!` empties the database at BOOT, so a run starts clean.
# Nothing kept it clean AFTER that. A test whose writes are not rolled back —
# `use_transactional_tests = false`, or a subprocess committing to the same DB —
# leaves rows in the ~51 tables no fixture covers, and Rails' fixture load will
# not remove them (it only truncates the ~28 tables it has fixtures for). Every
# later test in that process then sees them.
#
# The victim was never the polluter. `test/integration/test_database_hermeticity_test.rb`
# asserts the standing invariant, so IT went red — with `task_events: 1 row(s)` —
# in studio-engine's consumer lane, on a diff that never went near a task event.
# Whether it fired at all depended on whether minitest happened to shuffle it
# AFTER the polluter (Minitest shuffles the runnable CLASSES, so the same SHA
# re-ran green), which is why the failure read as flake and cost three sessions.
#
# The actual polluter, for the record: `ReviewPendingActionSettleRaceTest` runs
# non-transactionally (it must — two real connections race a row lock), created a
# Task per test, and cleaned up with `Task.where(slug:).delete_all`. `delete_all`
# skips callbacks AND `dependent: :destroy`, so the Task's genesis TaskEvent
# (`Task#record_genesis_event`) survived its parent. One orphan row per test —
# and CI distributes test METHODS across workers, so a worker that drew one of
# the two tests ended with exactly the one row the CI log named.
#
# THE FIX, and why it is prevention rather than another purge: a purge cleans up
# AFTER a leak, and a boot purge cannot see a leak that happens mid-run. This
# checks the same invariant the standing test asserts, but at the moment and place
# where the polluter is still identifiable — the teardown of the test that did it —
# and fails THAT test with its name on it. Containment (truncating what leaked) is
# the second half, not the first: it keeps one leaky test from poisoning the rest
# of the run, so the ordering lottery has nothing left to decide.
#
# WHERE IT RUNS: after EVERY test, once Rails' own teardown has rolled the test
# transaction back (see the hooks at the bottom of test/test_helper.rb, which is
# also the only place that arms this). Running post-rollback is what makes it
# cheap to be right — a transactional test's own writes are already gone, so any
# row still standing was genuinely committed by someone. Cost is one round trip
# per test (~0.24 ms measured, via TestDatabasePurge.nonempty_tables).
#
# THE BOUNDARY, stated plainly: the standalone `test/lib` / `test/commands` files
# are bare `minitest/autorun` and run with no Rails at all when invoked directly
# (`ruby -Itest test/lib/ship_test.rb`), so nothing here is armed for them then.
# In the `bin/rails test` sweep they ARE covered — the hook is installed on
# Minitest::Test — and the check no-ops whenever no database connection is
# established, because a process that never connected cannot have written.
module TestDatabaseLeakGuard
  class << self
    # The un-fixtured tables currently holding rows. Un-fixtured is the whole
    # blast radius: Rails re-loads fixtures (DELETE + INSERT) for the tables it
    # covers whenever a non-transactional test runs — `setup_fixtures`'s
    # non-transactional branch calls `invalidate_already_loaded_fixtures`, so the
    # next transactional test reloads them too — which means a stray row in a
    # FIXTURED table is cleaned by the harness itself. Nothing cleans the others.
    def leaked_tables(connection)
      TestDatabasePurge.nonempty_tables(unfixtured_tables(connection), connection)
    end

    # Detect → report → CONTAIN. Returns the per-table counts that leaked ({} when
    # clean), having emptied them so the next test starts from the same empty
    # database the boot purge promised.
    #
    # It truncates the WHOLE un-fixtured set, not just the tables that came back
    # dirty, and that is a foreign-key decision rather than a lazy one: Postgres
    # refuses to TRUNCATE a table another table references unless both are in the
    # same statement. Every FK in this schema whose PARENT is un-fixtured has an
    # un-fixtured CHILD as well (checked against db/schema.rb's 19 constraints; the
    # only fixtured child, roster_spots, points at fixtured rosters), so truncating
    # the set together is safe on its own terms — no reliance on
    # disable_referential_integrity, and no dependency on WHICH table happened to
    # leak. Same "one truncate for the whole graph" reasoning as TestDatabasePurge.
    def sweep!(connection)
      leaked = leaked_tables(connection)
      return {} if leaked.empty?

      counts = TestDatabasePurge.row_counts(leaked, connection)
      connection.truncate_tables(*unfixtured_tables(connection))
      counts
    end

    # The teardown hook body. Never raises anything but the assertion, and never
    # raises at all on a test that is already red — piling a second failure onto a
    # broken test buries the real one, and a test that blew up mid-way had no
    # chance to clean up after itself.
    def after_test(test)
      return unless armed?

      counts = sweep_with_retry
      return if counts.empty?
      return unless test.failures.empty?

      raise Minitest::Assertion, report(counts)
    rescue StandardError => e
      # A database blip in the GUARD must never invent a failure in a test that
      # was fine — warn loudly and let the run continue. This cannot swallow the
      # verdict above: Minitest::Assertion descends from Exception, not from
      # StandardError (checked, not assumed — Assertion.ancestors is
      # [Minitest::Assertion, Exception, …]).
      warn "test-database leak guard (non-fatal): #{e.class}: #{e.message}"
    end

    # One retry, for exactly one cause: a cached table list that no longer matches
    # the schema (nothing drops a table mid-run today; a test that created and
    # dropped one would). Re-derive the list and ask again — and if it fails a
    # second time, let it reach the warn above rather than looping.
    def sweep_with_retry
      ActiveRecord::Base.connection_pool.with_connection { |connection| sweep!(connection) }
    rescue ActiveRecord::StatementInvalid
      reset_cache!
      ActiveRecord::Base.connection_pool.with_connection { |connection| sweep!(connection) }
    end

    # Armed only when there is a live test database to look at. `connected?` and
    # not `connection` on purpose: this must never OPEN a connection just to ask
    # the question, because a process that never connected never wrote.
    def armed?
      defined?(ActiveRecord::Base) &&
        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test? &&
        ActiveRecord::Base.connection_pool.connected?
    rescue StandardError
      false
    end

    def report(counts)
      <<~MESSAGE
        LEAKED ROWS — this test left the test database dirty:

          #{counts.map { |table, count| "#{table}: #{count} row(s)" }.join("\n  ")}

        Those rows were not rolled back, and Rails' fixture load will not remove
        them: fixtures only truncate the tables they cover, and these are not among
        them. Every test that runs after this one in this process would have seen
        them — which is how an innocent test (usually the standing invariant in
        test/integration/test_database_hermeticity_test.rb) goes red instead, and
        only on the orderings that happen to put it last.

        This guard has already truncated them, so the rest of the run is clean. The
        FIX belongs in THIS test: clean up everything it wrote.

        The usual cause is `use_transactional_tests = false` plus a `delete_all`
        cleanup — `delete_all` skips callbacks AND `dependent: :destroy`, so child
        rows outlive the parent (a Task's genesis TaskEvent is the case that cost
        three sessions). Delete the children explicitly, or destroy the parent.

        If this test writes nothing, suspect a process OUTSIDE it committing to the
        same database mid-run — the e2e lane is the known one (playwright.config.js
        serves against this same test DB). Do not run both against one database.
      MESSAGE
    end

    # Memoized per database: the schema does not change during a run, and re-asking
    # the catalog (plus globbing test/fixtures) after every test would cost more
    # than the check itself.
    def unfixtured_tables(connection)
      key = connection.pool.db_config.database
      @unfixtured ||= {}
      @unfixtured[key] ||= TestDatabasePurge.unfixtured_tables(connection)
    end

    def reset_cache!
      @unfixtured = {}
    end
  end

  # Installed on ActiveSupport::TestCase, which sits AHEAD of ActiveRecord::TestFixtures
  # in the ancestor chain — so `super` here runs Rails' whole teardown, including the
  # transaction rollback in TestFixtures#after_teardown's `ensure`, before we look. Look
  # any earlier and every ordinary transactional test would report its own uncommitted
  # rows as a leak.
  module RailsHook
    def after_teardown
      super
    ensure
      TestDatabaseLeakGuard.after_test(self)
    end
  end

  # The same check for the bare `Minitest::Test` files (test/lib, test/commands) when
  # the sweep loads them alongside Rails. Skips ActiveSupport::TestCase instances so a
  # Rails test is checked ONCE, by RailsHook, on the post-rollback side.
  module BareHook
    def after_teardown
      super
    ensure
      unless defined?(ActiveSupport::TestCase) && is_a?(ActiveSupport::TestCase)
        TestDatabaseLeakGuard.after_test(self)
      end
    end
  end
end
