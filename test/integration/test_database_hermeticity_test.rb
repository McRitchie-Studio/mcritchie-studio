require "test_helper"

# The standing guard for the minitest database.
#
# Regression test for: the e2e lane (playwright.config.js's webServer) runs
# e2e/seed.rb against the SAME database minitest uses, and Rails truncates only
# the tables it has fixtures for — so the seed's rows in un-fixtured tables
# (pokemons, releases, task_events, …) used to SURVIVE into minitest and break
# tests that never touched the e2e lane (task_test's mascot tests: 8 errors and a
# failure, from a diff that never went near a mascot).
#
# These assert the POSITIVE invariant — "the database a minitest test sees holds
# only what fixtures and the test itself put there" — rather than blacklisting the
# ways it might get dirty. A blacklist ("pokemons must be empty") would pass while
# the other 44 un-fixtured tables stayed wide open, and would say nothing about the
# next table someone adds. This fails on ANY foreign row in ANY un-fixtured table,
# from ANY polluter, including ones nobody has thought of yet.
class TestDatabaseHermeticityTest < ActionDispatch::IntegrationTest
  test "no un-fixtured table carries rows from a foreign process" do
    unfixtured = TestDatabasePurge.unfixtured_tables
    polluted = TestDatabasePurge.row_counts(unfixtured)

    assert_empty polluted, <<~MESSAGE
      The minitest database is carrying rows that no fixture and no test created:

        #{polluted.map { |table, count| "#{table}: #{count} row(s)" }.join("\n  ")}

      Rails only truncates tables that have a fixture, so these rows survived the
      fixture load and are now visible to every test in this process. The usual
      culprit is the e2e lane — playwright.config.js's webServer runs e2e/seed.rb
      against this same database under RAILS_ENV=test — but ANY process that
      commits here does the same damage.

      Two things upstream of this message exist to prevent exactly that:
      test/test_helper.rb purges the database at boot, and TestDatabaseLeakGuard
      (test/support/test_database_leak_guard.rb) fails any TEST that leaves rows
      behind, at its own teardown, before this one ever runs. So if you are reading
      this, either the polluter is a process OUTSIDE this one (the e2e lane above),
      or one of those two is no longer running.

      Do not "fix" it by adding a fixture for the table above; that closes one hole
      and leaves the rest of the schema open.
    MESSAGE
  end

  # Guards the purge's REACH, not just today's cleanliness: the test above passes
  # trivially on a database that is empty for the wrong reason (e.g. if the table
  # list silently narrowed to nothing). This pins the fact that un-fixtured tables
  # genuinely exist and are genuinely in the purge's scope.
  test "the purge covers every table that fixtures do not" do
    unfixtured = TestDatabasePurge.unfixtured_tables

    assert_not_empty unfixtured,
                     "expected un-fixtured tables to exist — if this is empty the invariant above is vacuous"

    # The tables the e2e seed is known to write and no fixture covers. Spot-check
    # that they are inside the purge's scope, so a future refactor cannot quietly
    # drop them from it.
    %w[pokemons releases task_events agent_activities session_mascots].each do |table|
      assert_includes TestDatabasePurge.purgeable_tables, table,
                      "#{table} must be within the purge's reach — the e2e seed writes it"
      assert_includes unfixtured, table,
                      "#{table} has no fixture, so only the purge can clean it"
    end
  end
end
