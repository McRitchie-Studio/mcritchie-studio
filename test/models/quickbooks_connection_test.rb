require "test_helper"
require "support/quickbooks_connect_fakes"

# [unit] QuickbooksConnection: one QuickBooks Online company per row, keyed by
# its realm id, as the sign-in stores it, and the rotating refresh token each
# refresh replaces. Every token, id and name here is synthetic.
class QuickbooksConnectionTest < ActiveSupport::TestCase
  include QuickbooksConnectFakes

  TOKEN = "qbo-synthetic-refresh-0001".freeze
  NOW = Time.utc(2026, 11, 6, 22, 0, 0)

  def grant(**over) = quickbooks_grant(refresh_token: TOKEN, **over).transform_keys(&:to_s)

  def store(realm_id: REALM, **over)
    QuickbooksConnection.store!(grant(**over), realm_id:, company_name: "Synthetic Co", environment: "sandbox", by: "alex", now: NOW)
  end

  test "[unit] connection stores realm id and the refresh token as ciphertext at rest, with Intuit's stated expiry" do
    connection = store
    raw = QuickbooksConnection.connection.select_value("SELECT refresh_token FROM quickbooks_connections WHERE id = #{connection.id}")

    assert raw.present?
    assert_not_includes raw, TOKEN
    connection.reload
    assert_equal TOKEN, connection.refresh_token
    assert_equal REALM, connection.realm_id
    assert_equal "Synthetic Co", connection.company_name
    assert_equal "sandbox", connection.environment
    assert_equal NOW, connection.connected_at
    assert_equal NOW + 8_726_400.seconds, connection.refresh_token_expires_at
    assert_nil connection.last_refreshed_at
  end

  test "[unit] an inspect masks the refresh token" do
    connection = store

    assert_not_includes connection.inspect, TOKEN
    assert_includes connection.inspect, 'connected_by: "alex"' # the control: inspect does print this row
  end

  test "[unit] one row per company: the same realm again replaces its token, another realm is a second row" do
    store
    again = store(refresh_token: "second")
    assert_equal 1, QuickbooksConnection.count
    assert_equal "second", again.reload.refresh_token

    store(realm_id: "1234500000000002")
    assert_equal 2, QuickbooksConnection.count
    assert_equal 2, QuickbooksConnection.readable.size
  end

  test "[unit] a blank company name is stored under the label, and the environment must be sandbox or production" do
    connection = QuickbooksConnection.store!(grant, realm_id: REALM, company_name: " ", environment: "production", by: "alex")
    assert_equal QuickbooksConnection::LABEL, connection.company_name
    assert_not connection.sandbox?

    assert_raises(ActiveRecord::RecordInvalid) do
      QuickbooksConnection.store!(grant, realm_id: "1234500000000003", company_name: "x", environment: "staging", by: "alex")
    end
  end

  test "[unit] an answer with no refresh token is refused by field name" do
    error = assert_raises(ActiveRecord::RecordInvalid) { store(refresh_token: nil) }
    assert_match(/Refresh token/, error.message)
    assert_equal 0, QuickbooksConnection.count
  end

  test "[unit] connection rotates the refresh token: the answered one replaces the stored one, with its new expiry" do
    connection = store
    connection.rotate!({ "refresh_token" => "qbo-synthetic-refresh-0002", "x_refresh_token_expires_in" => 100 }, now: NOW + 5.minutes)

    connection.reload
    assert_equal "qbo-synthetic-refresh-0002", connection.refresh_token
    assert_equal NOW + 5.minutes, connection.last_refreshed_at
    assert_equal NOW + 5.minutes + 100.seconds, connection.refresh_token_expires_at
    assert_equal NOW, connection.connected_at, "a refresh is not a new sign-in"
  end

  test "[unit] a rotation that states no expiry keeps the old one; a blank token is refused and the stored one stays" do
    connection = store
    connection.rotate!({ "refresh_token" => "next" }, now: NOW + 1.minute)
    assert_equal NOW + 8_726_400.seconds, connection.reload.refresh_token_expires_at

    assert_raises(ArgumentError) { connection.rotate!({ "refresh_token" => "" }) }
    assert_equal "next", connection.reload.refresh_token
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a row stored under another key is unreadable, skipped, and replaced by the next sign-in" do
    old = store
    assert old.readable? # the control
    assert_equal [ old ], QuickbooksConnection.readable

    with_other_encryption_key do
      assert_not QuickbooksConnection.find(old.id).readable?
      assert_empty QuickbooksConnection.readable
      assert_no_difference -> { QuickbooksConnection.count } do
        store(refresh_token: "fresh")
      end
      row = QuickbooksConnection.sole
      assert_not_equal old.id, row.id
      assert_equal "fresh", row.refresh_token
    end
  end
end
