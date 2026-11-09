require "test_helper"

# The decisions behind installing an engine's migrations during the sweep.
#
# WHY THE SWEEP TOUCHES MIGRATIONS AT ALL: `<engine>:install:migrations` is a
# manual step, and every consumer asserts it was taken (EnginePinContractTest).
# The sweep publishes the gem — irreversibly — and commits each consumer's lock
# bump BEFORE the pre-QA gate runs those suites, so an engine release that adds a
# migration reddens every consumer after the point of no return. Measured on
# studio-engine PR 169: that assertion fired in all three consumer lanes.
#
# EVERY BRANCH BELOW IS A VALUE BECAUSE OF ONE REVIEW FINDING. The first cut kept
# this logic in bin/release.rb and its probe was FAIL-OPEN — any non-zero
# `bin/rails -T` read as "not an engine" — so on a live sweep, where the workspace
# bundle is never installed, the step skipped silently while the SOP told the
# operator migrations were handled. The pure helpers passed their tests the whole
# time, which is exactly why the decisions moved here.
class Release::EngineMigrationInstallTest < ActiveSupport::TestCase
  Install = Release::EngineMigrationInstall

  # --- which task -----------------------------------------------------------

  test "the install task follows the engine's railtie namespace" do
    assert_equal "studio_engine:install:migrations", Install.install_task("studio-engine")
    assert_equal "solana_studio:install:migrations", Install.install_task("solana-studio")
  end

  test "a blank gem name has no install task" do
    assert_nil Install.install_task(nil)
    assert_nil Install.install_task("  ")
  end

  # --- what the probe's answer means ----------------------------------------

  test "the task listed by a booting app is present" do
    out = "bin/rails studio_engine:install:migrations  # Copy migrations from studio_engine to application"

    assert_equal :present,
                 Install.probe_verdict(ok: true, output: out, task: "studio_engine:install:migrations")
  end

  # A gem that is not an engine. Exit 0, nothing listed — the ONLY silent skip.
  test "a booting app that lists nothing means the gem is not an engine" do
    assert_equal :absent,
                 Install.probe_verdict(ok: true, output: "", task: "solana_studio:install:migrations")
  end

  # THE DEFECT THIS FILE EXISTS FOR. `bundle lock` resolves without INSTALLING and
  # nothing else in the sweep installs the freshly-pushed version, so rails exits
  # 1 with Bundler::GemNotFound. Read as "not an engine", that skipped the whole
  # step on every live sweep — silently, with no log line at all.
  test "a non-zero probe is unbootable, never absent" do
    assert_equal :unbootable,
                 Install.probe_verdict(ok: false, output: "Could not find studio-engine-0.99.0 in locally installed gems",
                                       task: "studio_engine:install:migrations")
  end

  test "a non-zero probe is unbootable even when the output mentions the task" do
    assert_equal :unbootable,
                 Install.probe_verdict(ok: false, output: "studio_engine:install:migrations", task: "studio_engine:install:migrations")
  end

  test "no task to look for is absent rather than a crash" do
    assert_equal :absent, Install.probe_verdict(ok: true, output: "anything", task: nil)
  end

  # --- which database -------------------------------------------------------

  # Postgres consumers get a database of their own, named for the repo and this
  # process — never the shared <app>_test, and never another sweep's.
  test "a postgres consumer gets a throwaway database of its own" do
    url = Install.throwaway_database_url(
      base_url: "postgres://localhost/mcritchie_studio_test_ship", repo: "mcritchie-studio", pid: 4242
    )

    assert_equal "postgres://localhost/mcritchie_studio_release_schema_4242", url
  end

  test "two processes never collide on the same throwaway database" do
    one = Install.throwaway_database_url(base_url: "postgres:///x", repo: "turf-monster", pid: 1)
    two = Install.throwaway_database_url(base_url: "postgres:///x", repo: "turf-monster", pid: 2)

    refute_equal one, two
  end

  # A SQLITE app (rolio) must be handed NOTHING, so its own database.yml points at
  # a file inside the workspace. Handing it a postgres:// URL is a live trap this
  # repo warns about elsewhere; gate_database_url returns nil for sqlite, and this
  # carries that nil through rather than inventing a URL.
  test "a sqlite consumer is handed no database url at all" do
    assert_nil Install.throwaway_database_url(base_url: nil, repo: "rolio", pid: 7)
    assert_nil Install.throwaway_database_url(base_url: "", repo: "rolio", pid: 7)
  end

  test "an unparseable base url yields no url rather than a broken one" do
    assert_nil Install.throwaway_database_url(base_url: "postgres://user:pa ss@host/db", repo: "x", pid: 1)
  end

  # --- whether the dump may be committed ------------------------------------

  test "adding a table and moving the version stamp is safe" do
    diff = <<~DIFF
      --- a/db/schema.rb
      +++ b/db/schema.rb
      -ActiveRecord::Schema[8.1].define(version: 2026_08_18_120000) do
      +ActiveRecord::Schema[8.1].define(version: 2026_08_19_054500) do
      +  create_table "studio_geo_settings", force: :cascade do |t|
      +    t.string "app_name", null: false
      +  end
    DIFF

    assert Install.schema_dump_safe?(diff)
  end

  test "a dump that drops an existing table is refused" do
    diff = <<~DIFF
      -ActiveRecord::Schema[8.1].define(version: 2026_08_18_120000) do
      +ActiveRecord::Schema[8.1].define(version: 2026_08_19_054500) do
      -  create_table "legacy_things", force: :cascade do |t|
      -  end
    DIFF

    refute Install.schema_dump_safe?(diff)
  end

  test "a dump that rewrites a column is refused" do
    diff = "-    t.string \"email\", null: false\n+    t.text \"email\"\n"

    refute Install.schema_dump_safe?(diff)
  end

  # The `---` header starts with a dash and is not a removal. A guard that counted
  # it would refuse every diff, including the correct ones.
  test "the diff header is not read as a removal" do
    assert Install.schema_dump_safe?("--- a/db/schema.rb\n+++ b/db/schema.rb\n+  create_table \"x\"\n")
  end

  test "an empty diff is safe" do
    assert Install.schema_dump_safe?("")
    assert Install.schema_dump_safe?(nil)
  end

  # --- a check constraint Postgres re-printed after the load ----------------
  #
  # Measured 2026-11-08 on rel-20261108-f70996: turf-monster `users_role_known`
  # (`role IN ('viewer','admin')` on a varchar) came back from db:schema:load in a
  # different spelling, and the gate refused the whole sweep. Same meaning; the
  # gate must say so only on Postgres's word, and refuse everything else.

  ROLE_TEXT_ARRAY = "role::text = ANY (ARRAY['viewer'::character varying, 'admin'::character varying]::text[])"
  ROLE_PER_ELEMENT = "role::text = ANY (ARRAY['viewer'::character varying::text, 'admin'::character varying::text])"
  ROLE_WITH_OWNER = "role::text = ANY (ARRAY['viewer'::character varying::text, 'admin'::character varying::text, " \
                    "'owner'::character varying::text])"

  def check_line(expr, name = "users_role_known", options: "")
    %(    t.check_constraint #{expr.inspect}, name: #{name.inspect}#{options}\n)
  end

  def users_schema(expr, name = "users_role_known", column: true)
    <<~RUBY
      ActiveRecord::Schema[8.1].define(version: 2026_11_01_000000) do
        create_table "users", force: :cascade do |t|
      #{column ? '    t.string "role", default: "viewer", null: false' : ''}
      #{check_line(expr, name).chomp}
        end
      end
    RUBY
  end

  def check_diff(old_line, new_line)
    "--- a/db/schema.rb\n+++ b/db/schema.rb\n" \
      "-ActiveRecord::Schema[8.1].define(version: 2026_11_01_000000) do\n" \
      "+ActiveRecord::Schema[8.1].define(version: 2026_11_08_000000) do\n" \
      "#{old_line && "-#{old_line}"}#{new_line && "+#{new_line}"}"
  end

  # Postgres itself, on the hub's own test database: a varchar `role` table in a
  # savepoint, the gate's statements run in order, everything rolled back.
  def postgres_equivalent
    lambda do |table:, old_expr:, new_expr:|
      connection = ActiveRecord::Base.connection
      verdict = nil
      connection.transaction(requires_new: true) do
        connection.execute(%(CREATE TEMP TABLE "#{table}" (role varchar NOT NULL DEFAULT 'viewer')))
        statements = Install.check_equivalence_statements(table: table, old_expr: old_expr, new_expr: new_expr)
        statements[0...-1].each { |sql| connection.execute(sql) }
        verdict = Install.equivalence_verdict(ok: true, output: connection.select_value(statements.last) ? "t" : "f")
        raise ActiveRecord::Rollback
      end
      verdict
    rescue ActiveRecord::StatementInvalid
      false
    end
  end

  def safe_rewrite?(old_expr, new_expr, old_name: "users_role_known", new_name: "users_role_known",
                    equivalent: postgres_equivalent)
    Install.schema_dump_safe?(check_diff(check_line(old_expr, old_name), check_line(new_expr, new_name)),
                              old_schema: users_schema(old_expr, old_name),
                              new_schema: users_schema(new_expr, new_name),
                              equivalent: equivalent)
  end

  test "the two users_role_known spellings Postgres prints are accepted" do
    assert safe_rewrite?(ROLE_TEXT_ARRAY, ROLE_PER_ELEMENT)
    assert safe_rewrite?(ROLE_PER_ELEMENT, ROLE_TEXT_ARRAY)
  end

  test "the original IN spelling settles on the same text over more than one pass" do
    assert safe_rewrite?("role IN ('viewer','admin')", ROLE_PER_ELEMENT)
  end

  test "a changed constraint meaning is refused" do
    refute safe_rewrite?(ROLE_TEXT_ARRAY, ROLE_WITH_OWNER)
    refute safe_rewrite?(ROLE_PER_ELEMENT, "role::text = 'viewer'::text")
  end

  test "a renamed constraint is refused even when the expression is identical" do
    refute safe_rewrite?(ROLE_PER_ELEMENT, ROLE_PER_ELEMENT, new_name: "users_role_allowed")
  end

  test "a dropped constraint is refused" do
    diff = check_diff(check_line(ROLE_TEXT_ARRAY), nil)

    refute Install.schema_dump_safe?(diff, old_schema: users_schema(ROLE_TEXT_ARRAY), new_schema: users_schema(ROLE_TEXT_ARRAY),
                                           equivalent: ->(**) { true })
  end

  test "a dropped column is refused alongside a tolerated check rewrite" do
    diff = check_diff(check_line(ROLE_TEXT_ARRAY), check_line(ROLE_PER_ELEMENT)) +
           %(-    t.string "role", default: "viewer", null: false\n)

    refute Install.schema_dump_safe?(diff, old_schema: users_schema(ROLE_TEXT_ARRAY),
                                           new_schema: users_schema(ROLE_PER_ELEMENT, column: false),
                                           equivalent: ->(**) { true })
  end

  test "an expression that does not parse is refused, not raised" do
    refute safe_rewrite?(ROLE_TEXT_ARRAY, "role IN (")
  end

  test "without an equivalence callable a check rewrite still refuses" do
    refute safe_rewrite?(ROLE_TEXT_ARRAY, ROLE_PER_ELEMENT, equivalent: nil)
  end

  test "changed options beside the expression are refused" do
    diff = check_diff(check_line(ROLE_TEXT_ARRAY), check_line(ROLE_PER_ELEMENT, options: ", validate: false"))

    refute Install.schema_dump_safe?(diff, old_schema: users_schema(ROLE_TEXT_ARRAY), new_schema: users_schema(ROLE_PER_ELEMENT),
                                           equivalent: ->(**) { true })
  end

  test "a constraint that moved to another table is refused" do
    moved = users_schema(ROLE_PER_ELEMENT).sub('create_table "users"', 'create_table "members"')

    refute Install.schema_dump_safe?(check_diff(check_line(ROLE_TEXT_ARRAY), check_line(ROLE_PER_ELEMENT)),
                                     old_schema: users_schema(ROLE_TEXT_ARRAY), new_schema: moved,
                                     equivalent: ->(**) { true })
  end

  test "a name repeated across removed lines is refused" do
    diff = check_diff(check_line(ROLE_TEXT_ARRAY), check_line(ROLE_PER_ELEMENT)) + "-#{check_line(ROLE_TEXT_ARRAY)}"

    refute Install.schema_dump_safe?(diff, old_schema: users_schema(ROLE_TEXT_ARRAY), new_schema: users_schema(ROLE_PER_ELEMENT),
                                           equivalent: ->(**) { true })
  end

  test "the callable is handed the table and both expressions exactly as dumped" do
    seen = nil
    Install.schema_dump_safe?(check_diff(check_line(ROLE_TEXT_ARRAY), check_line(ROLE_PER_ELEMENT)),
                              old_schema: users_schema(ROLE_TEXT_ARRAY), new_schema: users_schema(ROLE_PER_ELEMENT),
                              equivalent: ->(**args) { seen = args; true })

    assert_equal({ table: "users", old_expr: ROLE_TEXT_ARRAY, new_expr: ROLE_PER_ELEMENT }, seen)
  end

  test "the psql script wraps the statements in a transaction it rolls back" do
    script = Install.check_equivalence_script(table: "users", old_expr: "a > 0", new_expr: "a > 0")

    assert script.start_with?("BEGIN;\n")
    assert script.end_with?("ROLLBACK;\n")
    assert_includes script, %(LIKE "users")
  end

  test "an expression carrying the DO block's quote tag is refused before any SQL" do
    assert_raises(ArgumentError) do
      Install.check_equivalence_statements(table: "users", old_expr: "x $release_schema_eq$", new_expr: "x")
    end
  end

  test "only a clean exit whose last line is t is proof" do
    assert Install.equivalence_verdict(ok: true, output: "t\n")
    refute Install.equivalence_verdict(ok: true, output: "f\n")
    refute Install.equivalence_verdict(ok: false, output: "t\n")
    refute Install.equivalence_verdict(ok: true, output: "")
  end

  # --- naming the cause (task schema-guard-names-engine-changes) -----------
  # On 2026-11-08 engine 0.138.0's NOT NULL migrations were refused with "the
  # committed schema was already behind its own migrations": wrong cause, no
  # migration name, no lines. The dump now runs in stages, so each refused line
  # is charged to the stage that produced it.

  ENGINE_MIGRATION = "20261108160000_require_slugs_on_engine_tables.studio_engine.rb"
  VERSION_DIFF = %(-ActiveRecord::Schema[7.2].define(version: 2026_11_01_000000) do\n) +
                 %(+ActiveRecord::Schema[7.2].define(version: 2026_11_08_160000) do\n)
  NOT_NULL_DIFF = %(@@ -10,3 +10,3 @@\n   create_table "error_logs", force: :cascade do |t|\n) +
                  %(-    t.string "slug"\n+    t.string "slug", null: false\n)
  NEW_TABLE_DIFF = %(@@ -40,0 +40,3 @@\n+  create_table "widgets", force: :cascade do |t|\n+    t.string "name"\n+  end\n)

  def stage(engine_migration, diff)
    { engine_migration: engine_migration, diff: "@@ -1 +1 @@\n#{VERSION_DIFF}#{diff}" }
  end

  test "the dump runs this repo's migrations first, then each engine migration alone, oldest first" do
    stages = Install.dump_stages(
      migration_files: %w[db/migrate/20261001000000_a.rb db/migrate/20261020000000_b.rb
                          db/migrate/20261108170000_role.studio_engine.rb db/migrate/20261108160000_slug.studio_engine.rb],
      engine_files: ["?? db/migrate/20261108170000_role.studio_engine.rb", "?? db/migrate/20261108160000_slug.studio_engine.rb"]
    )

    assert_equal [nil, "20261108160000_slug.studio_engine.rb", "20261108170000_role.studio_engine.rb"],
                 stages.map { |s| s[:engine_migration] }
    assert_equal %w[20261020000000 20261108160000 20261108170000], stages.map { |s| s[:version] }
    assert_equal %w[db:create db:schema:load db:migrate], stages.first[:tasks]
    assert_equal %w[db:migrate], stages.last[:tasks]
  end

  test "with no migration of its own the first stage re-dumps the loaded schema, never VERSION=0" do
    stages = Install.dump_stages(migration_files: [], engine_files: ["db/migrate/20261108160000_slug.studio_engine.rb"])

    assert_equal({ engine_migration: nil, tasks: %w[db:create db:schema:load db:schema:dump], version: nil }, stages.first)
  end

  test "an engine migration not above this repo's newest falls back to one unattributed stage" do
    stages = Install.dump_stages(migration_files: %w[db/migrate/20261201000000_late.rb],
                                 engine_files: ["db/migrate/20261108160000_slug.studio_engine.rb"])

    assert_equal 1, stages.length
    assert stages.first[:unattributed]
    assert_nil stages.first[:version], "every pending migration runs, as before the staging"
  end

  test "a NOT NULL change from a new engine migration is refused with that migration's name and lines" do
    message = Install.schema_refusal("turf-monster", [stage(nil, ""), stage(ENGINE_MIGRATION, NOT_NULL_DIFF)])

    assert_includes message, "turf-monster:"
    assert_includes message, "Engine migration #{ENGINE_MIGRATION} changed existing db/schema.rb lines"
    assert_includes message, %(-    t.string "slug"\n)
    assert_includes message, %(+    t.string "slug", null: false)
    assert_includes message, "rollback"
    refute_includes message, "behind its own migrations", "the engine migration is the cause, not a stale schema"
    refute_includes message, "define(version:", "the version line is expected and is not evidence"
  end

  test "a stale committed schema is reported as stale and names no engine migration" do
    message = Install.schema_refusal("cyvasse", [stage(nil, NOT_NULL_DIFF), stage(ENGINE_MIGRATION, NEW_TABLE_DIFF)])

    assert_includes message, "committed db/schema.rb was behind its own migrations"
    assert_includes message, %(-    t.string "slug")
    refute_includes message, ENGINE_MIGRATION, "an additive engine migration is not blamed"
  end

  test "stages that only add tables and move the version are not refused" do
    assert_nil Install.schema_refusal("rolio", [stage(nil, ""), stage(ENGINE_MIGRATION, NEW_TABLE_DIFF)])
  end

  test "the evidence leaves out an added table's hunk" do
    lines = Install.unsafe_change_lines(NOT_NULL_DIFF + NEW_TABLE_DIFF)

    assert_equal [%(-    t.string "slug"), %(+    t.string "slug", null: false)], lines
  end
end
