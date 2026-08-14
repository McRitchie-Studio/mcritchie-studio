# frozen_string_literal: true

require "test_helper"

# [unit] The installed copy of the engine's standard-profile migration must REFUSE
# to reverse.
#
# THIS FILE IS ALSO THE HUB'S DRIFT TRIPWIRE, and that is the larger reason it
# exists. `test/lib/engine_pin_contract_test.rb` checks which engine migrations are
# INSTALLED — by NAME. It cannot see a migration whose CONTENT changed in the gem,
# which is exactly what happened here: studio-engine rewrote this migration's
# `down` and the installed copy is a FORK, so a stale copy would have stayed GREEN
# forever. Asserting the behaviour closes that hole for this migration. A general
# content digest across every installed engine migration is tracked separately.
#
# Why a consumer-side test at all, when the engine has its own: engine migrations
# are install-COPIED (`bin/rails studio_engine:install:migrations`), not
# referenced. `bin/rails db:rollback` here runs the file in db/migrate, never the
# gem's — so a gem bump cannot deliver this guard, and the engine's green suite
# says nothing about this app's exposure.
#
# What it protects. mcritchie-studio owned `users.first_name` NATIVELY, long before
# the engine's first host-table migration existed. Measured on that exact shape
# before the fix: `up` then `down` left the column GONE and its data destroyed,
# with no error raised. The `up` guards every add with `if_not_exists` so it can
# run against apps that already disagree — and that guard is precisely why it
# cannot know, on the way out, which columns it created and which the host has
# owned for years.
#
# The refusal is WHOLESALE on purpose. Scoping it to "the four columns we added"
# would still leave `first_name` droppable, because the migration names it too and
# cannot tell that this app already had it.
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
