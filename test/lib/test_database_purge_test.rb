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

  # ---------------------------------------------------------------------------
  # THE GUARD. purge! empties EVERY table of whatever database the connection
  # holds, so it must PROVE that database is the test database before it fires.
  #
  # Every case below drives the guard with a FAKE connection (it records whether
  # truncate_tables was called) or a stubbed config — so a REFUSAL is proved
  # without ever pointing the real destructive path at a real database. A fake
  # that was never truncated is the whole assertion.
  # ---------------------------------------------------------------------------

  # Quacks like the two things purge! touches: pool.db_config.database, and the
  # truncate it must NOT reach on a refusal.
  class FakeConnection
    DbConfig = Struct.new(:database)
    Pool = Struct.new(:db_config)

    attr_reader :truncated

    def initialize(database)
      @database = database
      @truncated = nil
    end

    def pool = Pool.new(DbConfig.new(@database))
    def tables = %w[pokemons tasks users]
    def truncate_tables(*tables) = @truncated = tables
  end

  # The base the CURRENT lane calls its test DB (plain "…_test" in CI, the
  # isolated "…_test_<worktree>" in a worktree). Derived, never hardcoded, so
  # these cases assert the PROPERTY in every lane instead of one lane's spelling.
  def lane_test_db = TestDatabasePurge.configured_test_database

  test "GUARD 1: refuses when RAILS_ENV is not test — the proven stomp vector" do
    # test_helper.rb's `ENV["RAILS_ENV"] ||= "test"` does NOT override an exported
    # RAILS_ENV, and rails/test_help aborts only on production. So
    # `RAILS_ENV=development bin/rails test` boots the suite onto the SHARED
    # development database. Unguarded, the next line truncates all 73 of its tables.
    connection = FakeConnection.new("mcritchie_studio_development")

    error = assert_raises(TestDatabasePurge::UnsafeDatabase) do
      Rails.stub(:env, ActiveSupport::StringInquirer.new("development")) do
        TestDatabasePurge.purge!(connection)
      end
    end

    assert_nil connection.truncated, "REFUSAL must mean nothing was truncated"
    assert_match(/RAILS_ENV is "development"/, error.message)
  end

  test "GUARD 2: refuses when the env IS test but the connection holds a foreign database" do
    # This is the vector GUARD 1 CANNOT SEE: RAILS_ENV=test, but DATABASE_URL /
    # TEST_DATABASE_URL points the test env at the development database.
    connection = FakeConnection.new("mcritchie_studio_development")

    error = assert_raises(TestDatabasePurge::UnsafeDatabase) { TestDatabasePurge.purge!(connection) }

    assert_nil connection.truncated, "REFUSAL must mean nothing was truncated"
    assert_match(/mcritchie_studio_development/, error.message, "the refusal must NAME the database it spared")
    assert_match(/not this app's test database/, error.message)
  end

  test "GUARD 2 holds even when the resolved test config MOVED with the attack — the placebo case" do
    # MEASURED, not assumed (probe: RAILS_ENV=test DATABASE_URL=…/mcritchie_studio_development):
    # Rails merges DATABASE_URL into the config for the CURRENT env, and under the
    # suite that env IS test. So configs_for(env_name: "test").database ALSO reads
    # "mcritchie_studio_development" — a guard that compares the connection against
    # THAT config compares a moved value against itself, passes, and stomps the dev DB.
    #
    # This case pins the fix: the anchor is the `database:` LITERAL in database.yml,
    # which no ENV var can rewrite. Simulate the merge by moving the resolved config
    # onto the dev DB too — the purge must STILL refuse.
    connection = FakeConnection.new("mcritchie_studio_development")

    error = assert_raises(TestDatabasePurge::UnsafeDatabase) do
      TestDatabasePurge.stub(:configured_test_database, "mcritchie_studio_development") do
        TestDatabasePurge.purge!(connection)
      end
    end

    assert_nil connection.truncated, "the YAML anchor must refuse even when the resolved config was rewritten"
    assert_match(/mcritchie_studio_development/, error.message)
  end

  test "GUARD 2: refuses a look-alike database name that only shares a prefix" do
    # "app_testing_dev" shares the prefix "app_test" but is a DIFFERENT database.
    # A bare `start_with?(base)` would wave it through; the required separator does not.
    #
    # Both names are stubbed to the SAME base ON PURPOSE. Written against the live
    # lane instead, this case passed for the WRONG REASON: in a worktree the resolved
    # test DB ("…_test_<worktree>") differs from the declared one, so the drift lock
    # refused the look-alike and the separator rule was never exercised — the case
    # would have gone red only in CI, where declared == configured. Mutation M5
    # (bare prefix) exposed that; pinning both names makes the separator the only
    # thing that can refuse, in EVERY lane.
    TestDatabasePurge.stub(:declared_test_database, "app_test") do
      TestDatabasePurge.stub(:configured_test_database, "app_test") do
        connection = FakeConnection.new("app_testing_dev")

        error = assert_raises(TestDatabasePurge::UnsafeDatabase) { TestDatabasePurge.purge!(connection) }

        assert_nil connection.truncated
        assert_match(/app_testing_dev/, error.message)
      end
    end
  end

  test "GUARD: refuses cleanly when the test config is MISSING — a NoMethodError is a fail-open in disguise" do
    # configs_for(...) returns nil for an absent env, and declared_test_database digs
    # into a hash that may not have the key. A guard that dies on NoMethodError here
    # is not refusing — it is crashing, and the next person "fixes" it with a rescue.
    connection = FakeConnection.new(lane_test_db)

    error = assert_raises(TestDatabasePurge::UnsafeDatabase) do
      TestDatabasePurge.stub(:declared_test_database, nil) { TestDatabasePurge.purge!(connection) }
    end
    assert_match(/declares no `database:`/, error.message)
    assert_nil connection.truncated

    error = assert_raises(TestDatabasePurge::UnsafeDatabase) do
      TestDatabasePurge.stub(:configured_test_database, nil) { TestDatabasePurge.purge!(connection) }
    end
    assert_match(/drifted/, error.message)
    assert_nil connection.truncated
  end

  test "GUARD: refuses when the connection cannot report a database at all" do
    connection = FakeConnection.new(nil)

    assert_raises(TestDatabasePurge::UnsafeDatabase) { TestDatabasePurge.purge!(connection) }
    assert_nil connection.truncated
  end

  test "GUARD: refuses when the connection drifted off this lane's isolated test DB" do
    # A worktree/gate lane resolves an isolated test DB. A connection holding the
    # SHARED base test DB instead is the cross-lane stomp the isolation exists to
    # prevent — refuse it rather than truncate another lane's database.
    connection = FakeConnection.new("app_test")

    assert_raises(TestDatabasePurge::UnsafeDatabase) do
      TestDatabasePurge.stub(:declared_test_database, "app_test") do
        TestDatabasePurge.stub(:configured_test_database, "app_test_other_worktree") do
          TestDatabasePurge.purge!(connection)
        end
      end
    end
    assert_nil connection.truncated
  end

  test "GUARD: PASSES the legitimate lanes — base, parallel clone, and isolated worktree DBs" do
    # Anti-vacuity: a guard that refuses everything is not a guard, it is a brick.
    # Each of these is a database the suite genuinely runs against, and the purge
    # must fire on all three (asserted on the FAKE — no real database is touched).
    clone = FakeConnection.new("#{lane_test_db}-0") # Rails parallelize forks a DB per worker
    assert_nothing_raised { TestDatabasePurge.purge!(clone) }
    assert_equal %w[pokemons tasks users], clone.truncated

    TestDatabasePurge.stub(:declared_test_database, "app_test") do
      TestDatabasePurge.stub(:configured_test_database, "app_test") do
        base = FakeConnection.new("app_test")
        assert_nothing_raised { TestDatabasePurge.purge!(base) }
        assert_equal %w[pokemons tasks users], base.truncated

        worktree = FakeConnection.new("app_test_e2e_seed_poisons_test_db") # TEST_DATABASE_URL overlay
        assert_nothing_raised { TestDatabasePurge.purge!(worktree) }
        assert_equal %w[pokemons tasks users], worktree.truncated
      end
    end
  end

  # ---------------------------------------------------------------------------
  # THE RELEASE WORKSPACES. bin/release.rb runs the G3/G4 suites in isolated
  # workspaces whose test DBs are named by Release::GateWorkspace:
  # `<app>_gate_test` / `<app>_ship_test` — the role is INFIXED BEFORE `_test`,
  # so these do NOT start with `<base>` ("mcritchie_studio_test") at all and the
  # first cut of this guard FALSE-REFUSED them. That bricked every release.
  #
  # Both directions are pinned below, because this guard can fail two ways and
  # each failure is bad: too tight bricks the release, too loose re-opens the
  # dev-DB truncation hole the guard exists to close.
  # ---------------------------------------------------------------------------

  # How the gate workspace ACTUALLY presents itself to the guard (measured from
  # the failing gate run): `declared` is the YAML literal, which no ENV var can
  # move, while `configured` and the live connection BOTH carry the workspace's
  # DATABASE_URL overlay. Driving the fake through this shape is what makes these
  # cases the real lane rather than a convenient one.
  def in_workspace_lane(declared:, configured:, &block)
    TestDatabasePurge.stub(:declared_test_database, declared) do
      TestDatabasePurge.stub(:configured_test_database, configured, &block)
    end
  end

  test "GUARD: ADMITS the release gate + ship workspace DBs — the brick this bug was" do
    # REGRESSION (2026-07-14): `mcritchie_studio_gate_test` does not start with
    # `mcritchie_studio_test`, so the guard refused the gate's OWN database and the
    # pre-QA gate aborted for every repo, every release. Fails before the fix with
    # "REFUSING TO PURGE: `mcritchie_studio_gate_test` is not this app's test database".
    %w[gate ship].each do |role|
      db = "mcritchie_studio_#{role}_test"

      in_workspace_lane(declared: "mcritchie_studio_test", configured: db) do
        connection = FakeConnection.new(db)

        # Refusing this DB is what bricked the release: the gate purges its OWN
        # workspace database, and the guard would not let it.
        assert_nothing_raised { TestDatabasePurge.purge!(connection) }
        assert_equal %w[pokemons tasks users], connection.truncated,
                     "an admitted workspace DB must actually be purged"
      end
    end
  end

  test "GUARD: the admitted workspace DBs are EXACTLY the ones bin/release mints" do
    # Assert the PROPERTY, not two spellings: derive the names from the single
    # source of truth (Release::GateWorkspace, which bin/release.rb uses to create
    # them) so a new role or a renamed shape goes red HERE instead of bricking the
    # release again. The hardcoded list in the guard is what this pins in place.
    Release::GateWorkspace::ROLES.each do |role|
      db = Release::GateWorkspace.test_database_name("mcritchie-studio", role: role)

      assert TestDatabasePurge.derived_from?(db, "mcritchie_studio_test"),
             "#{db} is a database bin/release CREATES for the #{role} workspace — the guard must admit it"
    end

    # …and it is a CLOSED set, derived from the base — not a family of shapes.
    assert_equal %w[app_gate_test app_ship_test].sort,
                 Release::GateWorkspace::ROLES.map { |r| "app_#{r}_test" }.sort
  end

  test "GUARD: still REFUSES a foreign database and every workspace look-alike" do
    # The anti-widening case. The guard's whole value is that it refuses a
    # GENUINELY foreign database — it is what stops `RAILS_ENV=development
    # bin/rails test` from truncating all 73 tables of the dev DB. Admitting the
    # two workspace names must not become a substring or fuzzy match, so each of
    # these — every one of them adjacent to an admitted name — must STILL refuse.
    foreign = %w[
      mcritchie_studio_development
      mcritchie_studio_gate_testing
      mcritchie_studio_gate_test_dev
      other_app_gate_test
      mcritchie_studio_deploy_test
      gate_test
      _gate_test
    ]

    foreign.each do |db|
      in_workspace_lane(declared: "mcritchie_studio_test", configured: db) do
        connection = FakeConnection.new(db)

        error = assert_raises(TestDatabasePurge::UnsafeDatabase,
                              "#{db} is NOT derived from mcritchie_studio_test — admitting it re-opens the stomp") do
          TestDatabasePurge.purge!(connection)
        end

        assert_nil connection.truncated, "REFUSAL must mean nothing was truncated (#{db})"
        assert_match(/#{Regexp.escape(db)}/, error.message, "the refusal must NAME the database it spared")
      end
    end
  end

  test "GUARD: a base that is not a `_test` database mints no workspace names at all" do
    # The workspace names are DERIVED by stripping `_test` off the base. If a base
    # ever arrives without that suffix there is nothing to derive from, and the
    # guard must not invent an admission out of it.
    assert_not TestDatabasePurge.derived_from?("mcritchie_studio_gate_test", "mcritchie_studio_development")
    assert_not TestDatabasePurge.derived_from?("_gate_test", "_test")

    # SQLite lanes (rolio) resolve a FILE PATH, not a `<app>_test` identifier, so no
    # workspace name is derivable — and none is needed: that DB is private by living
    # inside the workspace. It still passes the guard by plain equality.
    sqlite = "/repo/.worktrees/_gate/storage/test.sqlite3"
    assert TestDatabasePurge.derived_from?(sqlite, sqlite), "the file-backed test DB is admitted by equality"
    assert_not TestDatabasePurge.derived_from?("/repo/storage/development.sqlite3", sqlite)
  end

  test "the real suite connection satisfies the guard — this run is proof" do
    # The purge above these lines already ran against the real test database on boot;
    # pin the invariant explicitly so a config change that breaks it fails HERE, loudly,
    # instead of turning every other test red.
    assert_equal ActiveRecord::Base.connection.pool.db_config.database,
                 TestDatabasePurge.assert_test_database!
  end
end
