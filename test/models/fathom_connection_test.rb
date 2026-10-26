require "test_helper"
require "support/fathom_connect_fakes"

# [unit] FathomConnection: the Fathom account the hub reads, as the sign-in
# stores it, and the single-use refresh token each refresh replaces. Every
# token here is synthetic.
class FathomConnectionTest < ActiveSupport::TestCase
  include FathomConnectFakes

  TOKEN = "fathom-synthetic-refresh-0001".freeze
  NOW = Time.utc(2026, 10, 15, 22, 0, 0)

  def grant(**over) = fathom_grant(refresh_token: TOKEN, **over).transform_keys(&:to_s)

  test "[unit] connection stores the refresh token as ciphertext at rest and reads it back in the clear" do
    connection = FathomConnection.store!(grant, account: "alex@mcritchie.studio", by: "alex", now: NOW)
    raw = FathomConnection.connection.select_value("SELECT refresh_token FROM fathom_connections WHERE id = #{connection.id}")

    assert raw.present?
    assert_not_includes raw, TOKEN
    assert_equal TOKEN, connection.reload.refresh_token
    assert_equal NOW, connection.connected_at
    assert_nil connection.last_refreshed_at
  end

  test "[unit] an inspect masks the refresh token" do
    connection = FathomConnection.store!(grant, account: "alex@mcritchie.studio", by: "alex", now: NOW)

    assert_not_includes connection.inspect, TOKEN
    assert_includes connection.inspect, 'connected_by: "alex"' # the control: inspect does print this row
  end

  test "[unit] signing the same account in again replaces its token, one row per account" do
    FathomConnection.store!(grant, account: "Alex McRitchie@McRitchie.studio", by: "alex", now: NOW)
    second = FathomConnection.store!(grant(refresh_token: "second"), account: "alex@mcritchie.studio", by: "alex", now: NOW + 1.hour)

    assert_equal 1, FathomConnection.count
    assert_equal "second", second.reload.refresh_token
    assert_equal second, FathomConnection.current
  end

  test "[unit] an account Fathom did not name is stored under the label" do
    connection = FathomConnection.store!(grant, account: nil, by: "alex", now: NOW)

    assert_equal FathomConnection::LABEL.downcase, connection.account
  end

  test "[unit] an answer with no refresh token is refused by field name" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      FathomConnection.store!(grant(refresh_token: nil), account: "alex@mcritchie.studio", by: "alex")
    end
    assert_match(/Refresh token/, error.message)
    assert_equal 0, FathomConnection.count
  end

  test "[unit] connection rotates the refresh token: the new one replaces the spent one and the refresh is stamped" do
    connection = FathomConnection.store!(grant, account: "alex@mcritchie.studio", by: "alex", now: NOW)
    connection.rotate!("fathom-synthetic-refresh-0002", now: NOW + 5.minutes)

    connection.reload
    assert_equal "fathom-synthetic-refresh-0002", connection.refresh_token
    assert_equal NOW + 5.minutes, connection.last_refreshed_at
    assert_equal NOW, connection.connected_at, "a refresh is not a new sign-in"
  end

  test "[unit] a blank rotation is refused and the stored token stays" do
    connection = FathomConnection.store!(grant, account: "alex@mcritchie.studio", by: "alex", now: NOW)

    assert_raises(ArgumentError) { connection.rotate!("") }
    assert_equal TOKEN, connection.reload.refresh_token
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a row stored under another key is unreadable, skipped, and replaced by the next sign-in" do
    old = FathomConnection.store!(grant, account: "alex@mcritchie.studio", by: "alex", now: NOW)
    assert old.readable? # the control
    assert_equal old, FathomConnection.readable

    with_other_encryption_key do
      assert_not FathomConnection.find(old.id).readable?
      assert_nil FathomConnection.readable
      assert_no_difference -> { FathomConnection.count } do
        FathomConnection.store!(grant(refresh_token: "fresh"), account: "alex@mcritchie.studio", by: "alex", now: NOW + 1.hour)
      end
      row = FathomConnection.current
      assert_not_equal old.id, row.id
      assert_equal "fresh", row.refresh_token
    end
  end
end
