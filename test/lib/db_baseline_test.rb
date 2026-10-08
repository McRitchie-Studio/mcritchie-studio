require "test_helper"

# [unit] The baseline generator and the marker that records it on an existing database.
class DbBaselineTest < ActiveSupport::TestCase
  SCHEMA = <<~RUBY
    ActiveRecord::Schema[8.1].define(version: 2026_02_01_000000) do
      # These are extensions that must be enabled in order to support this database
      enable_extension "pg_catalog.plpgsql"

      create_table "albums", force: :cascade do |t|
        t.string "artist_slug"
        t.string "state"
        t.index ["artist_slug"], name: "index_albums_on_artist_slug"
        t.check_constraint "state::text = 'live'::text", name: "albums_state_known"
      end

      create_table "artists", force: :cascade do |t|
        t.string "best_album_slug"
        t.string "slug", null: false
      end

      create_table "error_logs", force: :cascade do |t|
        t.text "message"
      end

      create_table "studio_links", force: :cascade do |t|
        t.string "token"
      end

      create_table "studio_things", force: :cascade do |t|
        t.string "name"
      end

      create_table "zebras", force: :cascade do |t|
        t.string "artist_slug"
      end

      add_foreign_key "albums", "artists", column: "artist_slug", primary_key: "slug"
      add_foreign_key "artists", "albums", column: "best_album_slug", primary_key: "slug"
      add_foreign_key "zebras", "artists", column: "artist_slug", primary_key: "slug"
    end
  RUBY

  OLD_FILES = {
    "20260110000000_create_albums.rb" => "class CreateAlbums; end",
    "20260111000000_add_state_to_albums.rb" => "class AddStateToAlbums; end",
    "20260112000000_create_studio_links.rb" => "create_table :studio_links",
    "20260113000000_allow_null_owner.rb" => "change_column_null :albums, :state, true",
    "20260114000000_create_studio_things.studio_engine.rb" => "create_table :studio_things do |t|",
    "20260115000000_ensure_error_logs_table.studio_engine.rb" => "unless table_exists?(:error_logs)\n create_table :error_logs",
    "20260301000000_create_newcomers.rb" => "create_table :newcomers"
  }.freeze

  ENGINE_NAMES = %w[create_studio_links allow_null_owner create_studio_things ensure_error_logs_table].freeze

  setup do
    @root = Dir.mktmpdir("db-baseline-test")
    FileUtils.mkdir_p(File.join(@root, "db/migrate"))
    FileUtils.mkdir_p(File.join(@root, "db/views"))
    OLD_FILES.each { |file, source| File.write(File.join(@root, "db/migrate", file), source) }
    File.write(File.join(@root, "db/views/album_timeline.sql"), "CREATE VIEW album_timeline AS\nSELECT state\nFROM albums\n")
  end

  teardown { FileUtils.rm_rf(@root) }

  def generator(schema = SCHEMA)
    DbBaseline::Generator.new(root: @root, schema_text: schema, engine_names: ENGINE_NAMES)
  end

  def source(name)
    File.read(Dir[File.join(@root, "db/migrate/*_#{name}.rb")].sole)
  end

  test "one_migration_per_table: each table gets one create migration, numbered before every kept file" do
    summary = generator.write!(ref: "abc123")

    assert_equal %w[
      20260101000001_enable_extensions.rb 20260101000002_create_error_logs.rb 20260101000003_create_studio_links.rb
      20260101000004_create_artists.rb 20260101000005_create_albums.rb 20260101000006_create_zebras.rb
      20260101000007_create_album_timeline_view.rb
    ], summary[:written]
    assert_equal %w[20260110000000_create_albums.rb 20260111000000_add_state_to_albums.rb 20260112000000_create_studio_links.rb],
                 summary[:retired], "a stand-in named create_<table> is replaced by the baseline file of the same name"
    assert_equal %w[
      20260113000000_allow_null_owner.rb 20260114000000_create_studio_things.studio_engine.rb
      20260115000000_ensure_error_logs_table.studio_engine.rb 20260301000000_create_newcomers.rb
    ], summary[:kept], "engine installs, a non-create stand-in and a migration newer than the schema all stay"
    assert_equal summary[:written] + summary[:kept], Dir.children(File.join(@root, "db/migrate")).sort
    assert_empty Dir[File.join(@root, "db/migrate/*studio_things*")].grep(/#{DbBaseline::PREFIX}/o),
                 "a table an engine migration creates with no guard has no baseline migration"
    assert_match(/class CreateStudioLinks < ActiveRecord::Migration\[8\.1\]/, source("create_studio_links"))
    assert_equal({ "retired_ref" => "abc123", "retired_through" => "20260201000000" }, YAML.load_file(File.join(@root, DbBaseline::RECORD)))
  end

  test "a baseline migration never forces a table" do
    generator.write!(ref: "abc123")

    Dir[File.join(@root, "db/migrate/#{DbBaseline::PREFIX}*.rb")].each do |path|
      assert_no_match(/force/, File.read(path), "#{File.basename(path)} would drop a live table")
    end
    assert_match(/create_table "albums" do \|t\|/, source("create_albums"))
  end

  test "views_and_checks_emitted: indexes, checks and foreign keys ride the table's migration; a view gets its own" do
    generator.write!(ref: "abc123")

    albums = source("create_albums")
    assert_includes albums, %(t.index ["artist_slug"], name: "index_albums_on_artist_slug")
    assert_includes albums, %(t.check_constraint "state::text = 'live'::text", name: "albums_state_known")
    assert_includes albums, %(add_foreign_key "albums", "artists", column: "artist_slug", primary_key: "slug")
    assert_includes albums, %(add_foreign_key "artists", "albums"), "the key of a cycle waits for the second table"
    assert_no_match(/add_foreign_key/, source("create_artists"))
    assert_includes source("create_zebras"), %(add_foreign_key "zebras", "artists")

    view = source("create_album_timeline_view")
    assert_includes view, "CREATE VIEW album_timeline AS"
    assert_includes view, %(execute("DROP VIEW IF EXISTS album_timeline"))
    assert_no_match(/DROP VIEW.*\n.*CREATE VIEW/, view, "up creates and never drops")
  end

  test "a second run rewrites the same baseline and keeps the record of the retired ledger" do
    first = generator.write!(ref: "abc123")
    before = first[:written].to_h { |file| [file, File.read(File.join(@root, "db/migrate", file))] }
    second = generator.write!(ref: "def456")

    assert_empty second[:retired]
    assert_equal before, second[:written].to_h { |file| [file, File.read(File.join(@root, "db/migrate", file))] }
    assert_equal "abc123", YAML.load_file(File.join(@root, DbBaseline::RECORD))["retired_ref"]
  end

  test "a schema statement the generator does not know stops it" do
    odd = SCHEMA.sub("  add_foreign_key \"zebras\"", "  create_enum \"mood\", [\"ok\"]\n  add_foreign_key \"zebras\"")

    error = assert_raises(DbBaseline::Error) { generator(odd).migrations }
    assert_includes error.message, "create_enum"
  end

  # --- the committed ledger ---------------------------------------------------

  test "every table in db/schema.rb has exactly one migration that creates it" do
    files = Dir[Rails.root.join("db/migrate/*.rb")].to_h { |path| [File.basename(path), File.read(path)] }
    tables = File.read(Rails.root.join("db/schema.rb")).scan(/^  create_table "(\w+)"/).flatten

    tables.each do |table|
      creators = files.select { |_, text| text.match?(/create_table\s+[:"]#{table}\b/) && !text.include?("table_exists?(:#{table})") }.keys
      assert_equal 1, creators.size, "#{table} is created by #{creators.inspect}"
    end
    assert_empty files.select { |file, text| DbBaseline.baseline_file?(file) && text.include?("force") }.keys
  end

  test "the marker can read every committed baseline migration" do
    entries = DbBaseline::Marker.new(connection: nil, migrate_dir: Rails.root.join("db/migrate")).entries

    assert_operator entries.size, :>, 100
    assert_equal entries.map(&:version), entries.map(&:version).uniq
    assert entries.select { |entry| entry.kind == :table }.all? { |entry| entry.columns.any? }
    assert_equal %w[release_timeline task_timeline], entries.select { |entry| entry.kind == :view }.map(&:name).sort
    assert_equal %w[releases tasks], entries.select { |entry| entry.kind == :view }.map(&:base).sort
  end

  test "the committed schema holds every column the baseline creates; a dump short of one is named" do
    schema = File.read(Rails.root.join("db/schema.rb"))
    clean = DbBaseline.compare(schema, root: Rails.root)

    assert_empty clean.short
    assert_empty clean.absent
    assert_not clean.behind

    opener = %(  create_table "tasks", force: :cascade do |t|\n)
    head, tail = schema.split(opener, 2)
    older = (head + opener + tail.sub(/^    t\.string "title".*\n/, "")).sub(/version: [\d_]+/, "version: 2026_09_01_000000")
    found = DbBaseline.compare("Running bin/rails db:schema:dump on a dyno\n#{older}\ntrailing noise", root: Rails.root)
    assert_equal ["tasks lacks title"], found.short
    assert found.behind
  end

  test "prepared_environments names every environment db:prepare migrates, as Rails does" do
    rails = lambda do |environment, env|
      seen = []
      original = ENV.to_h.slice("DATABASE_URL", "SKIP_TEST_DATABASE")
      begin
        %w[DATABASE_URL SKIP_TEST_DATABASE].each { |key| env.key?(key) ? ENV[key] = env[key] : ENV.delete(key) }
        ActiveRecord::Tasks::DatabaseTasks.send(:each_current_environment, environment) { |name| seen << name }
      ensure
        %w[DATABASE_URL SKIP_TEST_DATABASE].each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
      end
      seen
    end

    assert_equal %w[development test], DbBaseline.prepared_environments("development", env: {})
    [
      [ "development", {} ],
      [ "development", { "DATABASE_URL" => "postgresql://localhost/desk" } ],
      [ "development", { "SKIP_TEST_DATABASE" => "1" } ],
      [ "test", {} ],
      [ "production", {} ]
    ].each do |environment, env|
      assert_equal rails.call(environment, env), DbBaseline.prepared_environments(environment, env: env), "#{environment} #{env.inspect}"
    end
  end

  test "db:prepare marks every environment it migrates; db:migrate marks its own" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:baseline:mark")

    assert_includes Rake::Task["db:prepare"].prerequisites, "db:baseline:mark_prepared"
    assert_includes Rake::Task["db:migrate"].prerequisites, "db:baseline:mark"
  end

  test "the suite marks the test database before rails/test_help checks for pending migrations" do
    helper = File.read(Rails.root.join("test/test_helper.rb"))
    mark = helper.index('DbBaseline.mark_environment!("test"')
    assert mark, "test/test_helper.rb no longer marks the test database"
    assert_operator mark, :<, helper.index('require "rails/test_help"')
  end

  # --- the marker, against a scratch Postgres schema inside the test transaction ---

  class MarkerTest < ActiveSupport::TestCase
    setup do
      @dir = Dir.mktmpdir("db-baseline-marker")
      @connection = ActiveRecord::Base.connection
      @connection.execute("CREATE SCHEMA baseline_probe")
      @connection.execute("SET LOCAL search_path TO baseline_probe")
      write("20260101000001_create_albums.rb", %(create_table "albums" do |t|\n  t.string "title"\n  t.string "state"\n  t.index ["title"], name: "i"\nend))
      write("20260101000002_create_zebras.rb", %(create_table "zebras" do |t|\n  t.string "name"\nend))
      write("20260101000003_create_album_timeline_view.rb", "CREATE VIEW album_timeline AS\nSELECT title\nFROM albums")
      write("20260101000004_create_zebra_timeline_view.rb", "CREATE VIEW zebra_timeline AS\nSELECT name\nFROM zebras")
    end

    teardown { FileUtils.rm_rf(@dir) }

    def write(file, source) = File.write(File.join(@dir, file), source)

    def marker = DbBaseline::Marker.new(connection: @connection, migrate_dir: @dir)

    def ledger = @connection.select_values("SELECT version FROM schema_migrations ORDER BY version")

    def albums!(columns)
      @connection.create_table("albums") { |t| columns.each { |name| t.string name } }
    end

    # Every statement the block sends that is not a read.
    def writes
      seen = []
      all = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        all += 1
        seen << payload[:sql] unless payload[:sql].match?(/\A\s*(SELECT|SHOW)\b/i)
      end
      yield
      assert_operator all, :>, 0, "the probe saw no queries at all"
      seen
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test "records a table that holds every baseline column, leaves an absent one to migrate, and writes only the ledger" do
      albums!(%w[title state extra])
      found = nil
      statements = writes { found = marker.mark! }

      assert_equal %w[20260101000001 20260101000003], found.marked, "the view is recorded because its table exists"
      assert_equal %w[20260101000002_create_zebras.rb 20260101000004_create_zebra_timeline_view.rb], found.pending
      assert_equal %w[20260101000001 20260101000003], ledger
      assert_not @connection.view_exists?("album_timeline"), "a database without the view stays without it"
      assert statements.all? { |sql| sql.match?(/schema_migrations/) }, "wrote something other than the ledger: #{statements.inspect}"
      assert_empty writes { marker.mark! }.grep(/INSERT/), "a second run records nothing"
    end

    test "refuses a table that lacks a baseline column and records nothing" do
      albums!(%w[title])
      @connection.pool.schema_migration.create_table

      error = assert_raises(DbBaseline::Error) { marker.mark! }
      assert_includes error.message, "albums lacks state"
      assert_includes error.message, "bin/rails db:baseline:catch_up"
      assert_empty ledger
    end

    test "the report is read-only" do
      albums!(%w[title])
      @connection.pool.schema_migration.create_table
      found = nil

      assert_empty writes { found = marker.report }
      assert_equal ["albums lacks state"], found.short
      assert_empty ledger
    end

    test "control: a baseline migration run on an unmarked table raises and changes nothing" do
      albums!(%w[title state])

      error = assert_raises(ActiveRecord::StatementInvalid) do
        @connection.transaction(requires_new: true) { @connection.create_table("albums") { |t| t.string "title" } }
      end
      assert_kind_of PG::DuplicateTable, error.cause
      assert_equal %w[id state title], @connection.columns("albums").map(&:name).sort
    end
  end
end
