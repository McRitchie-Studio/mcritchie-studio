# Every Google connection gets an owner (/tasks/every-user-connects-google):
# any signed-in user may now connect their own Google account, and agents read
# only the household's (admin-owned) rows (GoogleConnection.household).
#
# BACKFILL. Each existing row was connected by an admin on /admin/google and
# names that admin's slug in `connected_by`. The row takes that user; a slug
# that no longer matches a user falls back to the operator
# (alex@mcritchie.studio), then to any admin. A row left with no owner stops
# the migration, so no connection silently drops out of the household.
#
# Raw SQL, not the models: a migration must still run when GoogleConnection and
# User have moved on.
class AddUserToGoogleConnections < ActiveRecord::Migration[8.1]
  OPERATOR_EMAIL = "alex@mcritchie.studio".freeze

  def up
    add_reference :google_connections, :user, foreign_key: { on_delete: :cascade }, index: true

    execute <<~SQL.squish
      UPDATE google_connections SET user_id = users.id
      FROM users WHERE users.slug = google_connections.connected_by AND google_connections.user_id IS NULL
    SQL
    fallback = select_value("SELECT id FROM users WHERE lower(email) = #{quote(OPERATOR_EMAIL)} LIMIT 1") ||
               select_value("SELECT id FROM users WHERE role = 'admin' ORDER BY id LIMIT 1")
    execute("UPDATE google_connections SET user_id = #{Integer(fallback)} WHERE user_id IS NULL") if fallback

    orphans = select_value("SELECT count(*) FROM google_connections WHERE user_id IS NULL").to_i
    raise "#{orphans} google_connections row(s) have no owner and no admin user exists to own them" if orphans.positive?

    change_column_null :google_connections, :user_id, false
  end

  def down
    remove_reference :google_connections, :user, foreign_key: true, index: true
  end

  private

  def quote(value) = connection.quote(value)
end
