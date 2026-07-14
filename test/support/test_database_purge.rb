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
module TestDatabasePurge
  # Rails' own bookkeeping. Truncating these would defeat the schema-version check
  # and force a pointless reload on every run.
  IGNORED_TABLES = %w[schema_migrations ar_internal_metadata].freeze

  class << self
    # Empty every application table. Returns the tables it truncated.
    def purge!(connection = ActiveRecord::Base.connection)
      tables = purgeable_tables(connection)
      return tables if tables.empty?

      # ONE truncate for the whole graph: Postgres resolves foreign-key cycles when
      # every table is truncated together, so no dependency ordering is needed here
      # (truncating table-by-table would trip FK constraints).
      connection.truncate_tables(*tables)
      tables
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
