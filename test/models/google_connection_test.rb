require "test_helper"
require "support/google_connect_fakes"
require Rails.root.join("db/migrate/20261014190000_rename_google_calendar_connections_to_google_connections")

# [unit] GoogleConnection: the Google account the hub reads, as the sign-in
# stores it, and the abilities its granted scopes unlock. Every token here is
# synthetic.
class GoogleConnectionTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  TOKEN = "1//synthetic-refresh-0001".freeze
  NOW = Time.utc(2026, 10, 13, 22, 0, 0)

  def grant(**over) = token_grant(refresh_token: TOKEN, **over).transform_keys(&:to_s)

  test "[unit] the refresh token is ciphertext at rest and reads back in the clear" do
    connection = GoogleConnection.store!(grant, email: "alex@mcritchie.studio", by: "alex", now: NOW)
    raw = GoogleConnection.connection.select_value("SELECT refresh_token FROM google_connections WHERE id = #{connection.id}")

    assert raw.present?
    assert_not_includes raw, TOKEN
    assert_equal TOKEN, connection.reload.refresh_token
  end

  test "[unit] an inspect masks the refresh token" do
    connection = GoogleConnection.store!(grant, email: "alex@mcritchie.studio", by: "alex", now: NOW)

    assert_not_includes connection.inspect, TOKEN
    assert_includes connection.inspect, 'connected_by: "alex"' # the control: inspect does print this row
  end

  test "[unit] signing the same account in again replaces its token, one row per account" do
    GoogleConnection.store!(grant, email: "Alex@McRitchie.studio", by: "alex", now: NOW)
    second = GoogleConnection.store!(grant(refresh_token: "1//second"), email: "alex@mcritchie.studio", by: "alex", now: NOW + 1.hour)

    assert_equal 1, GoogleConnection.count
    assert_equal "1//second", second.reload.refresh_token
    assert_equal second, GoogleConnection.current
  end

  test "[unit] current is the most recently connected account" do
    GoogleConnection.store!(grant, email: "a@example.com", by: "alex", now: NOW)
    later = GoogleConnection.store!(grant, email: "b@example.com", by: "alex", now: NOW + 1.minute)

    assert_equal later, GoogleConnection.current
  end

  test "[unit] an answer with no refresh token is refused by field name" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      GoogleConnection.store!(grant(refresh_token: nil), email: "alex@mcritchie.studio", by: "alex")
    end
    assert_match(/Refresh token/, error.message)
  end

  test "[unit] connection records granted scopes and answers per ability" do
    calendar = GoogleConnection.store!(grant, email: "a@example.com", by: "alex")
    unticked = GoogleConnection.store!(grant(scope: "openid email"), email: "b@example.com", by: "alex")

    assert calendar.can?(:calendar)
    refute calendar.can?(:gmail)
    refute calendar.can?(:drive)
    assert_equal [ :calendar ], calendar.abilities
    assert_empty unticked.abilities
    assert_raises(KeyError) { calendar.can?(:contacts) }
  end

  test "[unit] a second sign-in adds its scope to the ones already granted, one row" do
    GoogleConnection.store!(grant, email: "alex@mcritchie.studio", by: "alex", now: NOW)
    both = GoogleConnection.store!(grant(scope: "openid email #{DRIVE}", refresh_token: "1//drive"), email: "alex@mcritchie.studio", by: "alex", now: NOW + 1.hour)

    assert_equal 1, GoogleConnection.count
    assert_equal %i[calendar drive], both.reload.abilities
    assert_equal "1//drive", both.refresh_token, "the newest token carries every granted scope"
  end

  test "[unit] drop! forgets one ability and keeps the token for the rest" do
    connection = GoogleConnection.store!(grant(scope: "openid #{CALENDAR} #{GMAIL}"), email: "a@example.com", by: "alex")
    connection.drop!(:calendar)

    assert_equal [ :gmail ], connection.reload.abilities
    assert_equal TOKEN, connection.refresh_token
  end

  test "[unit] for(ability) is the newest readable connection granting it" do
    GoogleConnection.store!(grant, email: "a@example.com", by: "alex", now: NOW)
    drive = GoogleConnection.store!(grant(scope: DRIVE), email: "b@example.com", by: "alex", now: NOW + 1.minute)

    assert_equal "a@example.com", GoogleConnection.for(:calendar).email
    assert_equal drive, GoogleConnection.for(:drive)
    assert_nil GoogleConnection.for(:gmail)
  end

  test "[unit] ability reads a param and refuses anything else" do
    assert_equal :gmail, GoogleConnection.ability("gmail")
    assert_nil GoogleConnection.ability("contacts")
    assert_nil GoogleConnection.ability(nil)
  end

  test "[unit] the calendar row stored before the rename is still readable and still grants the calendar" do
    migration = RenameGoogleCalendarConnectionsToGoogleConnections.new
    migration.verbose = false
    migration.migrate(:down)
    legacy = Class.new(ApplicationRecord) do
      self.table_name = "google_calendar_connections"
      encrypts :refresh_token
      def self.name = "GoogleCalendarConnection"
    end
    legacy.create!(email: "alex@mcritchie.studio", refresh_token: TOKEN, scope: SCOPE, connected_at: NOW, connected_by: "alex")
    assert_not_includes legacy.connection.select_value("SELECT refresh_token FROM google_calendar_connections"), TOKEN

    migration.migrate(:up)
    GoogleConnection.reset_column_information
    row = GoogleConnection.find_by!(email: "alex@mcritchie.studio")

    assert row.readable?
    assert_equal TOKEN, row.refresh_token
    assert_equal [ :calendar ], row.abilities
    assert_equal row, GoogleConnection.for(:calendar)
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a row stored under another key is unreadable, and a new sign-in replaces it" do
    old = GoogleConnection.store!(grant, email: "alex@mcritchie.studio", by: "alex", now: NOW)
    assert old.readable? # the control

    with_other_encryption_key do
      assert_not GoogleConnection.find(old.id).readable?
      assert_no_difference -> { GoogleConnection.count } do
        GoogleConnection.store!(grant(refresh_token: "1//after-key-change"), email: "alex@mcritchie.studio", by: "alex", now: NOW + 1.day)
      end
      row = GoogleConnection.current
      assert_not_equal old.id, row.id
      assert_equal "1//after-key-change", row.refresh_token
    end
  end
end
