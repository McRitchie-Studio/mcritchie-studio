# TestDatabasePurge — make the minitest database HERMETIC.
#
# THE BUG THIS EXISTS TO KILL:
# Rails truncates only the tables it has a FIXTURE for. Every other table keeps
# whatever a previous process COMMITTED to the test database. That is not a
# hypothetical: the e2e lane's Playwright `webServer` (playwright.config.js) runs
#
#     bin/rails db:test:prepare && bin/rails runner e2e/seed.rb && bin/rails server -e test
#
# under RAILS_ENV=test — i.e. against the SAME database minitest uses. The seed
# writes to tables that have no fixture (pokemons, releases, task_events,
# agent_activities, agent_actions, session_mascots, action_grades, …), those rows
# SURVIVE fixture truncation, and they then break minitest tests that never went
# near the e2e lane: a seeded Pokemon deck makes task_test's "deck is unseeded"
# mascot test fail, and the seed's slugs collide with that suite's own
# seed_pokemon helper. A builder sees a red mascot test and hunts a phantom
# regression in their own diff.
#
# It is not a Pokemon problem. Of this schema's tables, only ~28 have fixtures —
# the other ~45 are all equally unprotected, and the seed is only one of the
# processes that can reach them (a stray `bin/rails runner`, a `db:seed`
# fat-finger, and a killed test that committed all land the same way).
#
# THE FIX:
# Do not trust the fixture set to clean the database. EMPTY the database, then let
# fixtures load into it. The invariant is positive and total, and it does not care
# who the polluter was:
#
#     a minitest process starts from an empty database, whatever any other
#     process left behind.
#
# The table list is derived from the live schema on every run, so a new table is
# covered the day it is created — there is no list here to forget to update.
#
# THE GUARD (why this file FAILS CLOSED before it truncates anything):
# This code empties every table of whatever database the connection holds. That is
# safe only while that database is the test database — and NOTHING in the test
# harness guarantees it. `test_helper.rb`'s `ENV["RAILS_ENV"] ||= "test"` does not
# override an ALREADY-EXPORTED RAILS_ENV, and `rails/test_help` aborts only on
# production ("Make double-sure the RAILS_ENV is not set to production"), so
# `RAILS_ENV=development bin/rails test` boots the suite straight onto the shared
# development database. An unguarded purge would then truncate all 73 tables of
# mcritchie_studio_development — the DB every worktree's plain `bin/rails` hits.
#
# So: ask the booted app what database it is ACTUALLY connected to, and refuse
# unless it proves out as this app's test database. Same doctrine as the release
# gate's assert_private_gate_db! (bin/release.rb) — "a guarantee that rests on
# every future app's config being right is a CONVENTION, not an invariant... ask
# the booted app, and treat a shared DB as a hard abort — never a silent stomp."
module TestDatabasePurge
  # Rails' own bookkeeping. Truncating these would defeat the schema-version check
  # and force a pointless reload on every run.
  IGNORED_TABLES = %w[schema_migrations ar_internal_metadata].freeze

  # Raised INSTEAD of truncating. Never rescue this to "get the suite running":
  # it means the suite was about to empty a database that is not the test database.
  class UnsafeDatabase < StandardError; end

  class << self
    # Empty every application table. Returns the tables it truncated.
    # Refuses (raises UnsafeDatabase) unless the connection provably holds this
    # app's test database — see assert_test_database!.
    def purge!(connection = ActiveRecord::Base.connection)
      assert_test_database!(connection)

      tables = purgeable_tables(connection)
      return tables if tables.empty?

      # ONE truncate for the whole graph: Postgres resolves foreign-key cycles when
      # every table is truncated together, so no dependency ordering is needed here
      # (truncating table-by-table would trip FK constraints).
      connection.truncate_tables(*tables)
      tables
    end

    # Fail closed on BOTH of the independent things that can be wrong: the ENV the
    # process is running as, and the DATABASE the connection actually holds.
    def assert_test_database!(connection = ActiveRecord::Base.connection)
      unless Rails.env.test?
        refuse!("RAILS_ENV is #{Rails.env.inspect}, not \"test\"",
                "Nothing here may truncate a non-test database. If you meant to run the suite, " \
                "unset RAILS_ENV (test_helper's `ENV[\"RAILS_ENV\"] ||= \"test\"` cannot override an exported one).")
      end

      resolved = connected_database(connection)
      refuse!("the connection does not report a database name") if resolved.blank?

      # ANCHOR: the `database:` literal in config/database.yml's test env. This is
      # the one expectation an ENV var CANNOT MOVE — and that is the whole point.
      #
      # Why the obvious check (resolved == configs_for(env_name: "test").database)
      # is a PLACEBO here, measured on this app: Rails merges DATABASE_URL into the
      # config FOR THE CURRENT ENV (DatabaseConfigurations#merge_db_environment_variables),
      # and under the suite the current env IS test. So `RAILS_ENV=test
      # DATABASE_URL=postgresql://localhost/mcritchie_studio_development` rewrites the
      # TEST config to the development DB: connection and expectation BOTH read
      # "mcritchie_studio_development", the equality passes, and the purge stomps the
      # shared dev DB. Comparing a value against a config the same ENV var just
      # rewrote is comparing a moved value to itself. The YAML literal does not move.
      declared = declared_test_database
      if declared.blank?
        refuse!("config/database.yml declares no `database:` for the test env",
                "Without that literal there is no env-independent name to check the connection against, " \
                "and this purge will not guess. Declare `test.database:` in config/database.yml.")
      end

      unless derived_from?(resolved, declared)
        refuse!("`#{resolved}` is not this app's test database (config/database.yml declares `#{declared}`)",
                "REFUSING to truncate it. A purge here would destroy every row in that database. " \
                "Cause: RAILS_ENV/DATABASE_URL/TEST_DATABASE_URL is pointing the test env at a foreign database.")
      end

      # Second, independent lock: the live connection must also match the test
      # config the app RESOLVED. Catches a connection that drifted from that config
      # (a stray establish_connection, a `connects_to` shard, a recycled pool) —
      # cases the YAML anchor alone would wave through.
      configured = configured_test_database
      unless configured.present? && derived_from?(resolved, configured)
        refuse!("the connection holds `#{resolved}` but the test env resolves to #{configured.inspect}",
                "The connection drifted from the configured test database. REFUSING to truncate.")
      end

      resolved
    end

    # The database the connection ACTUALLY holds. Read from the connection PASSED IN
    # — not from ActiveRecord::Base — because purge! accepts a connection, and
    # guarding a different connection than the one being truncated is a fail-open.
    def connected_database(connection = ActiveRecord::Base.connection)
      connection.pool.db_config.database
    rescue NoMethodError
      nil
    end

    # The env-INDEPENDENT anchor: the `database:` literal under `test:` in
    # config/database.yml. No ENV var rewrites it (unlike the resolved config).
    def declared_test_database
      Rails.application.config.database_configuration.dig("test", "database")
    end

    # The test database the app RESOLVED for this boot (YAML + TEST_DATABASE_URL /
    # DATABASE_URL overlays). Nil when the test env is missing entirely — the caller
    # must treat that as a refusal, never as a pass.
    def configured_test_database
      ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "primary")&.database
    end

    # The roles bin/release.rb runs an ISOLATED WORKSPACE for — kept in lockstep with
    # Release::GateWorkspace::ROLES (the code that actually mints these databases) by
    # a test, not by hope. Duplicated rather than referenced on purpose: this guard is
    # the last thing standing between a stray boot and a truncated database, and it
    # will not have its refusal logic depend on an autoloadable app model.
    WORKSPACE_ROLES = %w[gate ship].freeze

    # Is `name` the base test database, or one of its LEGITIMATE derivatives?
    #   "<base>"            the base test DB itself
    #   "<base>-0"          Rails parallel-test clones (parallelize forks a DB per worker)
    #   "<base>_<slug>"     per-worktree isolated test DBs (TEST_DATABASE_URL)
    #   "<app>_gate_test"   bin/release.rb's isolated GATE workspace  ┐ role INFIXED
    #   "<app>_ship_test"   bin/release.rb's isolated SHIP workspace  ┘ before `_test`
    #   "<app>_gate_test-0" parallel-test clone of a workspace DB — the release gate
    #                       runs its OWN suite parallelized, so the gate workspace DB
    #                       forks to "<app>_gate_test-0" per worker, exactly as the base
    #                       forks to "<base>-0". Admitted on the SAME "-" boundary.
    #
    # The separator is REQUIRED on the prefix rules, so a look-alike like
    # "mcritchie_studio_testing_dev" does not sneak through on a bare prefix match.
    #
    # The workspace DBs (added 2026-07-14) do not fit those rules AT ALL: the role is
    # infixed BEFORE `_test`, so "mcritchie_studio_gate_test" does not begin with
    # "mcritchie_studio_test" and the first cut of this guard FALSE-REFUSED the release
    # gate's own database — bricking every release the day it landed. They are admitted
    # as an EXACT, CLOSED SET derived from the base (workspace_databases), never as a
    # loosened prefix/substring rule: widening this predicate to wave them through by
    # shape would also wave through "mcritchie_studio_development", which is precisely
    # the database this guard exists to spare.
    def derived_from?(name, base)
      return false if name.blank? || base.blank?

      name == base ||
        name.start_with?("#{base}-") ||
        name.start_with?("#{base}_") ||
        workspace_databases(base).any? { |wdb| name == wdb || name.start_with?("#{wdb}-") }
    end

    # The release workspaces' FIXED test-DB names, derived from the base test DB:
    #   "mcritchie_studio_test" -> ["mcritchie_studio_gate_test", "mcritchie_studio_ship_test"]
    # Exact names only — the caller matches by EQUALITY. Returns nothing when the base
    # is not an "<app>_test" identifier (a SQLite lane's file path, say): there is then
    # no app name to derive from, and this will not invent one.
    def workspace_databases(base)
      base = base.to_s
      return [] unless base.end_with?("_test")

      app = base.delete_suffix("_test")
      return [] if app.blank?

      WORKSPACE_ROLES.map { |role| "#{app}_#{role}_test" }
    end

    def refuse!(reason, remedy = nil)
      raise UnsafeDatabase, [
        "REFUSING TO PURGE: #{reason}.",
        remedy,
        "(test/support/test_database_purge.rb empties EVERY table; it runs only against the test database.)"
      ].compact.join(" ")
    end

    def purgeable_tables(connection = ActiveRecord::Base.connection)
      connection.tables.sort - IGNORED_TABLES
    end

    # The tables Rails will NOT clean on fixture load — i.e. exactly the tables
    # where a foreign process's committed rows would otherwise survive into a test.
    # This is the blast radius the purge closes, and the invariant test asserts it.
    def unfixtured_tables(connection = ActiveRecord::Base.connection)
      purgeable_tables(connection) - fixture_table_names
    end

    # Fixture files map to table names by their path under test/fixtures, so
    # `test/fixtures/theme_settings.yml` covers `theme_settings`.
    def fixture_table_names
      root = File.expand_path("../fixtures", __dir__)
      Dir[File.join(root, "**", "*.yml")].map do |path|
        path.delete_prefix("#{root}/").delete_suffix(".yml")
      end.sort
    end

    def row_counts(tables, connection = ActiveRecord::Base.connection)
      tables.each_with_object({}) do |table, counts|
        count = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
        counts[table] = count if count.positive?
      end
    end
  end
end
