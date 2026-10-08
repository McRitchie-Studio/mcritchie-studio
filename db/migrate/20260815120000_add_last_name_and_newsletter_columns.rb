# The standard profile columns this app was missing — hand-written, and named to
# match the engine's future migration EXACTLY.
#
# WHY A HAND-WRITTEN COPY RATHER THAN WAITING FOR THE ENGINE'S. Engine migrations
# are install-COPIED (`bin/rails studio_engine:install:migrations`), never
# referenced, and the copy is a manual step a gem bump does not perform. So there
# is a window between the engine shipping a migration and every consumer
# installing it, and during that window `test/lib/engine_pin_contract_test.rb`
# (turf-monster's, and its siblings) goes RED for every app that has not caught
# up — it asserts `engine_migration_names - installed_migration_names` is empty.
#
# Going CONSUMER-FIRST closes that window entirely. That gate compares BARE names
# (leading timestamp stripped, `.studio_engine` suffix stripped), so an app that
# already holds a migration of this name is satisfied the moment the engine ships
# its own, and `install:migrations` then SKIPS it — "Migration with the same name
# already exists". `create_studio_links` and `allow_null_image_cache_owner` are
# already in exactly this state here, and that guard's own comment calls it
# "correct rather than drift".
#
# SO THE NAME IS LOAD-BEARING. `add_last_name_and_newsletter_columns` must match
# the engine's migration character for character. Rename either side and the
# whole arrangement collapses into the red window it exists to avoid.
#
# NO PROVENANCE HEADER, deliberately. `engine_migration_content_test.rb` compares
# only files that either carry the `.studio_engine` suffix or a
# "# This migration comes from studio_engine" line. A plain migration matches
# neither, so it is never compared and cannot be reported as drift against the
# engine's copy — which is right, because the two are independent files that
# happen to share a name and an effect.
#
# EVERY ADD IS `if_not_exists`, for the same reason the engine's
# AddStandardUserProfileColumns is: the apps disagree TODAY. This app already owns
# `last_name`; turf-monster owns all three; mcritchie-industries owns none. One
# file has to be safe on all of them.
class AddLastNameAndNewsletterColumns < ActiveRecord::Migration[8.1]
  def up
    # An app that keeps its accounts under another name is simply skipped, same
    # as the engine's standard-columns migration.
    return unless table_exists?(:users)

    add_column :users, :last_name, :string, if_not_exists: true

    # The newsletter pair: when this account JOINED the list, and when it LEFT.
    # Two timestamps rather than one boolean, because "subscribed" is derived
    # (joined after left) and the dates themselves are the durable fact — a
    # boolean cannot answer "when did they leave" or survive a rejoin.
    add_column :users, :joined_email_list_at, :datetime, if_not_exists: true
    add_column :users, :left_email_list_at, :datetime, if_not_exists: true
  end

  def down
    return unless table_exists?(:users)

    # REFUSES, for the reason the engine's own standard-columns migration
    # refuses: `up` is idempotent by design, so it records NOTHING about which of
    # these columns it actually created on this host and which were already here.
    # This app owned `last_name` long before this file existed, and Rails' auto
    # inverse would drop it. `if_exists` is not the fix — it asks "does the column
    # exist", and here it does; that IS the hazard.
    raise ActiveRecord::IrreversibleMigration, <<~MSG
      AddLastNameAndNewsletterColumns cannot be reversed safely.

      Its `up` adds last_name, joined_email_list_at and left_email_list_at with
      `if_not_exists`, so it does not know which it created and which this app
      already owned — and this app owned `last_name` before this migration
      existed. Dropping all three would destroy that data.

      If you truly want a column gone, drop the one you know this app did not own
      beforehand, by hand, in its own migration.
    MSG
  end
end
