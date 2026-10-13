require "test_helper"
require "support/google_calendar_fakes"

# [unit] GoogleCalendarConnection: the Google account whose calendar the hub
# reads, as the sign-in stores it. Every token here is synthetic.
class GoogleCalendarConnectionTest < ActiveSupport::TestCase
  include GoogleCalendarFakes

  TOKEN = "1//synthetic-refresh-0001".freeze
  NOW = Time.utc(2026, 10, 13, 22, 0, 0)

  def grant(**over) = token_grant(refresh_token: TOKEN, **over).transform_keys(&:to_s)

  test "[unit] the refresh token is ciphertext at rest and reads back in the clear" do
    connection = GoogleCalendarConnection.store!(grant, email: "alex@mcritchie.studio", by: "alex", now: NOW)
    raw = GoogleCalendarConnection.connection.select_value("SELECT refresh_token FROM google_calendar_connections WHERE id = #{connection.id}")

    assert raw.present?
    assert_not_includes raw, TOKEN
    assert_equal TOKEN, connection.reload.refresh_token
  end

  test "[unit] an inspect masks the refresh token" do
    connection = GoogleCalendarConnection.store!(grant, email: "alex@mcritchie.studio", by: "alex", now: NOW)

    assert_not_includes connection.inspect, TOKEN
    assert_includes connection.inspect, 'connected_by: "alex"' # the control: inspect does print this row
  end

  test "[unit] signing the same account in again replaces its token, one row per account" do
    GoogleCalendarConnection.store!(grant, email: "Alex@McRitchie.studio", by: "alex", now: NOW)
    second = GoogleCalendarConnection.store!(grant(refresh_token: "1//second"), email: "alex@mcritchie.studio", by: "alex", now: NOW + 1.hour)

    assert_equal 1, GoogleCalendarConnection.count
    assert_equal "1//second", second.reload.refresh_token
    assert_equal second, GoogleCalendarConnection.current
  end

  test "[unit] current is the most recently connected account" do
    GoogleCalendarConnection.store!(grant, email: "a@example.com", by: "alex", now: NOW)
    later = GoogleCalendarConnection.store!(grant, email: "b@example.com", by: "alex", now: NOW + 1.minute)

    assert_equal later, GoogleCalendarConnection.current
  end

  test "[unit] an answer with no refresh token is refused by field name" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      GoogleCalendarConnection.store!(grant(refresh_token: nil), email: "alex@mcritchie.studio", by: "alex")
    end
    assert_match(/Refresh token/, error.message)
  end

  test "[unit] can_read_calendar? is true only when Google granted the calendar scope" do
    full = GoogleCalendarConnection.store!(grant, email: "a@example.com", by: "alex")
    unticked = GoogleCalendarConnection.store!(grant(scope: "openid email"), email: "b@example.com", by: "alex")

    assert full.can_read_calendar?
    refute unticked.can_read_calendar?
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a row stored under another key is unreadable, and a new sign-in replaces it" do
    old = GoogleCalendarConnection.store!(grant, email: "alex@mcritchie.studio", by: "alex", now: NOW)
    assert old.readable? # the control

    with_other_encryption_key do
      assert_not GoogleCalendarConnection.find(old.id).readable?
      assert_no_difference -> { GoogleCalendarConnection.count } do
        GoogleCalendarConnection.store!(grant(refresh_token: "1//after-key-change"), email: "alex@mcritchie.studio", by: "alex", now: NOW + 1.day)
      end
      row = GoogleCalendarConnection.current
      assert_not_equal old.id, row.id
      assert_equal "1//after-key-change", row.refresh_token
    end
  end
end
