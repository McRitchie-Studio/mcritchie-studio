require "test_helper"
require "open3"
require "pg"

# [integration] The committed ledger, run for real against a scratch database:
# a fresh database migrated from zero dumps db/schema.rb exactly, and a database
# that already holds the tables is recorded and left untouched.
class DbBaselineMarkTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    base = URI(ENV["TEST_DATABASE_URL"].presence || ENV["DATABASE_URL"].presence || "postgresql://localhost")
    @database = "baseline_probe_#{Process.pid}_#{SecureRandom.hex(3)}"
    base.path = "/#{@database}"
    @url = base.to_s
    @dump = Rails.root.join("tmp", "#{@database}.schema.rb").to_s
    rails!("db:create")
  end

  teardown do
    rails!("db:drop", allow_failure: true)
    FileUtils.rm_f(@dump)
  end

  def rails!(*tasks, allow_failure: false)
    env = { "RAILS_ENV" => "test", "DATABASE_URL" => @url, "TEST_DATABASE_URL" => @url, "SCHEMA" => @dump,
            "DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1" }
    output, status = Open3.capture2e(env, "bin/rails", *tasks, chdir: Rails.root.to_s)
    flunk "bin/rails #{tasks.join(' ')} failed:\n#{output.last(2000)}" unless status.success? || allow_failure
    [output, status]
  end

  def scratch
    connection = PG.connect(@url)
    yield connection
  ensure
    connection&.close
  end

  # Tables, columns, indexes and constraints, as Postgres holds them.
  def fingerprint(connection)
    [
      "SELECT table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = 'public' ORDER BY 1, 2",
      "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1",
      "SELECT conname, convalidated, pg_get_constraintdef(oid) FROM pg_constraint WHERE connamespace = 'public'::regnamespace ORDER BY 1",
      "SELECT viewname, definition FROM pg_views WHERE schemaname = 'public' ORDER BY 1"
    ].map { |sql| connection.exec(sql).values }
  end

  test "fresh_migrate_matches_schema_rb, then old_ledger_db_migrates_nothing" do
    # A fresh database, migrated from zero, dumps the committed schema.
    rails!("db:migrate")
    assert_equal File.read(Rails.root.join("db/schema.rb")), File.read(@dump),
                 "db:migrate on an empty database must dump db/schema.rb exactly"

    # The same database as the retired ledger left it: every table, no baseline version.
    before = scratch do |connection|
      assert_equal %w[release_timeline task_timeline], connection.exec("SELECT viewname FROM pg_views WHERE schemaname = 'public' ORDER BY 1").column_values(0)
      connection.exec("INSERT INTO agents (name, slug, created_at, updated_at) VALUES ('Probe', 'probe', now(), now())")
      removed = connection.exec("DELETE FROM schema_migrations WHERE version LIKE '#{DbBaseline::PREFIX}%'").cmd_tuples
      assert_operator removed, :>, 100
      fingerprint(connection)
    end

    # Control: unmarked, a baseline migration collides with the table it creates.
    version = File.basename(Dir[Rails.root.join("db/migrate/#{DbBaseline::PREFIX}*_create_agents.rb")].sole)[/\A\d+/]
    output, status = rails!("db:migrate:up", "VERSION=#{version}", allow_failure: true)
    assert_not status.success?, "an unmarked baseline migration ran against a live table"
    assert_includes output, "PG::DuplicateTable"

    # Marked by db:migrate itself: nothing runs, nothing changes but the ledger.
    output, = rails!("db:migrate")
    assert_match(/db:baseline:mark recorded \d+ baseline versions; no table changed/, output)
    assert_no_match(/^== /, output, "db:migrate ran a migration on a database that already held every table")
    scratch do |connection|
      assert_equal before, fingerprint(connection)
      assert_equal 1, connection.exec("SELECT count(*) FROM agents WHERE slug = 'probe'").getvalue(0, 0).to_i
      assert_equal Dir[Rails.root.join("db/migrate/*.rb")].size, connection.exec("SELECT count(*) FROM schema_migrations").getvalue(0, 0).to_i,
                   "the ledger holds one row per migration file"
    end
    assert_equal File.read(Rails.root.join("db/schema.rb")), File.read(@dump)
  end
end
