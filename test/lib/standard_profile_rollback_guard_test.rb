# frozen_string_literal: true

require "test_helper"

# [unit] The installed copy of the engine's standard-profile migration must REFUSE to
# reverse, and this is the hub's DRIFT TRIPWIRE. `bin/rails db:rollback` runs the
# install-COPIED file, never the gem's, so a gem bump cannot deliver this.
# test/lib/engine_migration_content_test.rb digests code; only this says a rollback would
# take the hub's first_name. `up` guards adds with `if_not_exists`, so on the way out it
# cannot know which columns it created. The refusal is WHOLESALE on purpose: "the four
# columns we added" leaves `first_name` droppable.
# History: task detect-engine-migration-content-drift.
class StandardProfileRollbackGuardTest < ActiveSupport::TestCase
  MIGRATION = Rails.root.glob("db/migrate/*_add_standard_user_profile_columns.studio_engine.rb").freeze

  test "exactly one copy of the engine profile migration is installed" do
    # Two copies under different timestamps share a class name, and Rails groups
    # migrations by NAME — a duplicate raises DuplicateMigrationNameError on every
    # db:migrate, including the Heroku release phase. This app carried a second
    # copy on an open PR earlier the same day.
    assert_equal 1, MIGRATION.length,
      "expected exactly one installed copy, found: #{MIGRATION.map(&:basename).map(&:to_s).inspect}"
  end

  test "the installed migration refuses to reverse instead of dropping columns" do
    require MIGRATION.sole.to_s

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddStandardUserProfileColumns.new.migrate(:down)
    end
    assert_match(/cannot be reversed safely/, error.message)
  end

  test "a refused rollback leaves the hub's natively-owned first_name intact" do
    require MIGRATION.sole.to_s

    before = User.columns_hash.keys.sort
    assert_includes before, "first_name", "precondition: the hub owns first_name natively"

    assert_raises(ActiveRecord::IrreversibleMigration) do
      AddStandardUserProfileColumns.new.migrate(:down)
    end

    User.reset_column_information
    assert_equal before, User.columns_hash.keys.sort, "a refused rollback must drop nothing"
  end
end
