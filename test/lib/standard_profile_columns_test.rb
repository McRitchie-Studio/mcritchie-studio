require "test_helper"

# [unit] The standard profile columns, and the MIGRATION NAME that keeps this app
# out of the engine's red window.
#
# WHY THE NAME MATTERS MORE THAN THE COLUMNS. Engine migrations are install-COPIED
# (`bin/rails studio_engine:install:migrations`), never referenced, and the copy is
# a manual step a gem bump does not perform. So between the engine SHIPPING a
# migration and every consumer INSTALLING it, `test/lib/engine_pin_contract_test.rb`
# goes red here — it asserts `engine_migration_names - installed_migration_names`
# is empty.
#
# Going consumer-FIRST closes that window, and it works because that gate compares
# BARE names: leading timestamp stripped, `.studio_engine` suffix stripped. An app
# already holding a migration of the engine's name is satisfied the moment the
# engine ships, and `install:migrations` then skips it ("Migration with the same
# name already exists"). `create_studio_links` is already in exactly this state.
#
# All of which rests on the two names matching CHARACTER FOR CHARACTER. Rename
# either side and the arrangement silently collapses back into the red window it
# exists to avoid — silently, because nothing goes red until the engine ships,
# which may be days later and in a different repo. That is what this file pins.
class StandardProfileColumnsTest < ActiveSupport::TestCase
  # The engine will ship a migration of exactly this bare name. Changing it here
  # without changing it there — or the reverse — reopens the red window.
  EXPECTED_NAME = "add_last_name_and_newsletter_columns".freeze

  STANDARD_COLUMNS = %w[last_name joined_email_list_at left_email_list_at].freeze

  def bare_names
    Dir.children(Rails.root.join("db/migrate"))
       .grep(/\.rb\z/)
       .map { |f| f.sub(/\A\d+_/, "").sub(/\.[a-z_]+\.rb\z/, "").sub(/\.rb\z/, "") }
  end

  test "the users table carries every standard profile column" do
    missing = STANDARD_COLUMNS - User.column_names

    assert_empty missing,
                 "users is missing #{missing.join(", ")} — /profile's rows are gated on " \
                 "`requires:`, so the fields do not raise, they silently do not render"
  end

  # THE LOAD-BEARING ASSERTION. Asserted by BARE name because that is the only
  # form the engine's gate compares — the timestamp differs on every host and the
  # engine's copy carries a `.studio_engine` suffix this one must not.
  test "the migration is named exactly what the engine will ship" do
    assert_includes bare_names, EXPECTED_NAME,
                    "no migration named #{EXPECTED_NAME} in db/migrate. The engine ships one " \
                    "under that name; without a match here, engine_pin_contract_test goes RED " \
                    "the moment the engine's version lands."
  end

  # A hand-written migration must stay invisible to the CONTENT gate, which
  # compares only files carrying the engine's provenance line or scope suffix.
  # Adding either would make this file claim to be a copy of the engine's — and
  # it is not, it is an independent file that happens to share a name and effect.
  test "the migration does not claim to be an engine copy" do
    path = Dir[Rails.root.join("db/migrate/*_#{EXPECTED_NAME}.rb")].first
    refute_nil path, "expected a plain (non-suffixed) migration named #{EXPECTED_NAME}"

    source = File.read(path)

    # ANCHORED TO THE FIRST LINE, matching engine_migration_content_test's own
    # PROVENANCE regex (`/\A#[ \t]*This migration comes from .../`) rather than
    # searching the whole file. An unanchored version is stricter than the real
    # rule and fires on PROSE — it failed on this very migration's comment, which
    # explains the header in order to say why it is absent. A guard that is
    # stricter than the thing it guards is a guard nobody can satisfy honestly.
    refute_match(/\A#[ \t]*This migration comes from /, source,
                 "the provenance header makes engine_migration_content_test compare this file " \
                 "against the gem's and report drift for a file that was never a copy")
    refute_match(/\.studio_engine\.rb\z/, File.basename(path),
                 "the scope suffix is what `install:migrations` writes; a hand-written migration " \
                 "must not wear it")
  end

  # `if_not_exists` is what lets ONE file be correct on apps that disagree — this
  # one already owned last_name, turf-monster owns all three, mcritchie-industries
  # owns none. Without it the migration raises on the apps that are ahead.
  test "every add tolerates a column the app already owns" do
    source = File.read(Dir[Rails.root.join("db/migrate/*_#{EXPECTED_NAME}.rb")].first)
    adds = source.scan(/add_column[^\n]*/)

    assert_equal STANDARD_COLUMNS.length, adds.length,
                 "expected one add_column per standard column"
    adds.each do |line|
      assert_match(/if_not_exists:\s*true/, line,
                   "`#{line.strip}` would raise on an app that already owns that column")
    end
  end
end
