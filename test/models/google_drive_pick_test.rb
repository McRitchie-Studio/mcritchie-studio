require "test_helper"
require "support/google_connect_fakes"

# [unit] drive-files-you-pick: the drive ability is drive.file and reads only
# picked files; a legacy drive.readonly row keeps working, is never widened,
# and reconnecting Drive retires its old scope. GoogleDrivePick records one
# picked file per connection, never a folder, and goes with its connection.
class GoogleDrivePickTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  def alex = users(:alex)
  def pick!(connection, id = "f1", **over) = connection.drive_picks.create!(file_id: id, name: "Q3 plan", picked_at: Time.current, **over)

  test "[unit] Drive asks for drive.file, and a drive.file row reads picked files, not the legacy whole Drive" do
    assert_equal "https://www.googleapis.com/auth/drive.file", GoogleConnection.scope_for(:drive)
    connection = store_google(scope: "openid #{DRIVE}")

    assert connection.can?(:drive)
    assert connection.drive_picked?
    refute connection.legacy?(:drive)
  end

  test "[unit] a legacy drive.readonly row still grants Drive and says it is legacy" do
    connection = store_google(scope: "openid #{DRIVE_LEGACY}", abilities: [ :calendar ])
    connection.update_columns(scope: "openid #{DRIVE_LEGACY}") # stored before drive.file: written directly

    assert connection.can?(:drive), "keeps working until it reconnects"
    assert connection.legacy?(:drive)
    refute connection.drive_picked?
    assert_equal [ :drive ], connection.abilities
  end

  test "[unit] reconnecting Drive retires drive.readonly even when Google echoes it, so nothing widens" do
    connection = store_google(scope: "openid #{CALENDAR}", abilities: [ :calendar ])
    connection.update_columns(scope: "openid #{CALENDAR} #{DRIVE_LEGACY}")

    again = store_google(scope: "openid #{CALENDAR} #{DRIVE_LEGACY} #{DRIVE}", abilities: [ :drive ])

    assert_equal connection.id, again.id
    assert_equal %W[openid #{CALENDAR} #{DRIVE}].sort, again.scopes.sort
    refute again.legacy?(:drive)
  end

  test "[unit] another ability's sign-in leaves a legacy row's Drive as it was, and never adds drive.readonly" do
    connection = store_google(scope: "openid #{CALENDAR}", abilities: [ :calendar ])
    connection.update_columns(scope: "openid #{CALENDAR} #{DRIVE_LEGACY}")
    assert store_google(scope: "openid #{GMAIL} #{DRIVE_LEGACY}", abilities: [ :gmail ]).legacy?(:drive), "untouched"

    fresh = store_google(email: "new@gmail.test", scope: "openid #{GMAIL} #{DRIVE_LEGACY}", abilities: [ :gmail ])
    refute_includes fresh.scopes, DRIVE_LEGACY, "an echoed legacy grant is never taken"
    refute fresh.can?(:drive)
  end

  test "[unit] dropping Drive forgets the picks and both Drive scopes; deleting the row takes its picks" do
    connection = store_google(scope: "openid #{CALENDAR} #{DRIVE} #{DRIVE_LEGACY}")
    pick!(connection)

    connection.drop!(:drive)
    refute connection.reload.can?(:drive)
    assert_equal 0, GoogleDrivePick.count

    pick!(store_google(scope: "openid #{DRIVE}", abilities: [ :drive ]))
    GoogleConnection.where(id: connection.id).delete_all # what GoogleSignIn#disconnect_all does
    assert_equal 0, GoogleDrivePick.count, "the foreign key cascades past delete_all"
  end

  test "[unit] a pick is one file per connection, with a Drive id, and never a folder" do
    connection = store_google(scope: "openid #{DRIVE}")
    pick!(connection)

    assert_raises(ActiveRecord::RecordInvalid) { pick!(connection) }
    assert_raises(ActiveRecord::RecordInvalid) { pick!(connection, "../x") }
    folder = connection.drive_picks.new(file_id: "d1", name: "Clients", mime_type: GoogleDrivePick::FOLDER_MIME, picked_at: Time.current)
    refute folder.valid?
    assert_includes folder.errors.full_messages.to_sentence, "share it with your agent's address"
  end
end
