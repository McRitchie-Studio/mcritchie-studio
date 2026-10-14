# One Google connection per account now covers Calendar, Gmail and Drive, each
# an ability its granted scopes unlock (GoogleConnection). A rename, not a
# copy: the stored rows, their encrypted refresh tokens and their granted
# `scope` strings carry over untouched, so the connected calendar stays
# connected. Active Record Encryption keys nothing on the table or class name,
# so the tokens still decrypt (test/models/google_connection_test.rb proves it).
#
# The baseline marker reads the literal rename_table line above `down`
# (DbBaseline.renamed_tables), so keep it a string-literal call in `up`.
class RenameGoogleCalendarConnectionsToGoogleConnections < ActiveRecord::Migration[8.1]
  def up
    rename_table "google_calendar_connections", "google_connections"
  end

  def down
    rename_table "google_connections", "google_calendar_connections"
  end
end
