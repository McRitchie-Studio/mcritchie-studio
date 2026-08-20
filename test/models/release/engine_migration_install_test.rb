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
end
