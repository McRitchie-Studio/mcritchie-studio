require "test_helper"

# The two decisions behind installing an engine's migrations during the sweep.
#
# WHY THE SWEEP TOUCHES MIGRATIONS AT ALL: `<engine>:install:migrations` is a
# manual step, and every consumer asserts it was taken (EnginePinContractTest).
# The sweep publishes the gem — irreversibly — and commits each consumer's lock
# bump BEFORE the pre-QA gate runs those suites, so an engine release that adds a
# migration reddens every consumer after the point of no return. Measured on
# studio-engine PR 169: that assertion fired in all three consumer lanes.
class Release::EngineMigrationInstallTest < ActiveSupport::TestCase
  # Rails' own convention for an engine's railtie namespace. `studio-engine`
  # installs with `studio_engine:install:migrations`; the caller checks whether
  # the task EXISTS, because most published gems are not engines.
  test "the install task follows the engine's railtie namespace" do
    assert_equal "studio_engine:install:migrations",
                 Release::ShipSequence.migration_install_task("studio-engine")
    assert_equal "solana_studio:install:migrations",
                 Release::ShipSequence.migration_install_task("solana-studio")
  end

  test "a blank gem name has no install task" do
    assert_nil Release::ShipSequence.migration_install_task(nil)
    assert_nil Release::ShipSequence.migration_install_task("  ")
  end

  # --- the schema guard -----------------------------------------------------
  #
  # Installing a migration ADDS a table and moves the version stamp. Anything
  # else means the consumer's committed schema was already behind its own
  # migrations, and the sweep would smuggle that drift into a commit labelled
  # "bump gem for QA".

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

    assert Release::ShipSequence.schema_dump_safe?(diff)
  end

  test "a dump that drops an existing table is refused" do
    diff = <<~DIFF
      --- a/db/schema.rb
      +++ b/db/schema.rb
      -ActiveRecord::Schema[8.1].define(version: 2026_08_18_120000) do
      +ActiveRecord::Schema[8.1].define(version: 2026_08_19_054500) do
      -  create_table "legacy_things", force: :cascade do |t|
      -  end
    DIFF

    refute Release::ShipSequence.schema_dump_safe?(diff)
  end

  test "a dump that rewrites a column is refused" do
    diff = <<~DIFF
      --- a/db/schema.rb
      +++ b/db/schema.rb
      -    t.string "email", null: false
      +    t.text "email"
    DIFF

    refute Release::ShipSequence.schema_dump_safe?(diff)
  end

  # The `---` header line starts with a dash and is not a removal. A guard that
  # counted it would refuse every diff, including the correct ones.
  test "the diff header is not read as a removal" do
    diff = "--- a/db/schema.rb\n+++ b/db/schema.rb\n+  create_table \"x\"\n"

    assert Release::ShipSequence.schema_dump_safe?(diff)
  end

  test "an empty diff is safe" do
    assert Release::ShipSequence.schema_dump_safe?("")
    assert Release::ShipSequence.schema_dump_safe?(nil)
  end
end
