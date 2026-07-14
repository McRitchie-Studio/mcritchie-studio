require "test_helper"

# Unit cover for the purge that keeps the minitest database hermetic.
# See test/support/test_database_purge.rb for the bug it exists to kill.
class TestDatabasePurgeTest < ActiveSupport::TestCase
  test "purge! empties a table that has no fixture" do
    # Reproduces the e2e seed's write: a Pokemon deck in a table with no fixture.
    # Without the purge these rows survive the fixture load and break task_test.
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "purge-snorlax", generation: 1)
    Pokemon.create!(dex: 25, name: "Pikachu", slug: "purge-pikachu", generation: 1)
    assert_equal 2, Pokemon.count

    TestDatabasePurge.purge!

    assert_equal 0, Pokemon.count, "purge! must empty un-fixtured tables — fixture truncation never will"
  end

  test "purge! empties fixtured tables too, so the database starts truly empty" do
    # Totality is the point: the purge does not reason about which tables are
    # "safe". Fixtures reload into the empty database immediately afterward.
    assert_operator Task.count, :>, 0, "expected fixtures to have loaded"

    TestDatabasePurge.purge!

    assert_equal 0, Task.count
    assert_equal 0, User.count
  end

  test "purge! truncates the whole graph despite foreign keys" do
    # A single TRUNCATE over every table lets Postgres resolve FK cycles. Purging
    # table-by-table would raise on a referenced parent — this pins that it does not.
    task = Task.create!(title: "Purge graph fk task")
    TaskEvent.create!(task_slug: task.slug, kind: TaskEvent::TRANSITION,
                      to_stage: "building", occurred_at: Time.current)
    assert_operator TaskEvent.count, :>, 0

    assert_nothing_raised { TestDatabasePurge.purge! }

    assert_equal 0, TaskEvent.count
    assert_equal 0, Task.count
  end

  test "the table list is derived from the live schema, not hardcoded" do
    # A hardcoded list rots: the next table someone adds would silently fall out of
    # the purge and reopen the hole. Prove the list comes from the connection.
    assert_includes TestDatabasePurge.purgeable_tables, "pokemons"
    assert_equal ActiveRecord::Base.connection.tables.sort - TestDatabasePurge::IGNORED_TABLES,
                 TestDatabasePurge.purgeable_tables
  end

  test "purge! leaves Rails' schema bookkeeping alone" do
    # Truncating these would defeat the schema-version check and force a reload.
    TestDatabasePurge.purge!

    assert_operator ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM schema_migrations").to_i, :>, 0
    assert_not_includes TestDatabasePurge.purgeable_tables, "schema_migrations"
    assert_not_includes TestDatabasePurge.purgeable_tables, "ar_internal_metadata"
  end

  test "unfixtured_tables names exactly the tables fixture truncation cannot reach" do
    unfixtured = TestDatabasePurge.unfixtured_tables

    # Has a fixture => Rails already truncates it => outside this set.
    assert_not_includes unfixtured, "tasks"
    assert_not_includes unfixtured, "users"

    # No fixture => survives fixture truncation => this is the exposed surface.
    assert_includes unfixtured, "pokemons"
    assert_includes unfixtured, "task_events"
  end

  test "row_counts reports only tables that actually carry rows" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "counts-snorlax", generation: 1)

    counts = TestDatabasePurge.row_counts(%w[pokemons releases])

    assert_equal 1, counts["pokemons"]
    assert_not_includes counts.keys, "releases", "empty tables must not be reported as polluted"
  end
end
