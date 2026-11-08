require "test_helper"
require "support/msgraph_connect_fakes"

# [unit] MsgraphConnection: a Microsoft 365 tenant the hub reads app-only, as
# the admin-consent callback stores it. The tenant id is encrypted, digested
# for uniqueness, and never printed. Every tenant id here is synthetic.
class MsgraphConnectionTest < ActiveSupport::TestCase
  include MsgraphConnectFakes

  NOW = Time.utc(2026, 11, 6, 20, 0, 0)

  def store(tenant_id: TENANT, display_name: "Synthetic Org", now: NOW)
    MsgraphConnection.store!(tenant_id:, display_name:, by: "alex", now:)
  end

  test "[unit] the tenant id is ciphertext at rest, reads back in the clear, and the key is a digest" do
    connection = store
    raw = MsgraphConnection.connection.select_one("SELECT tenant_id, tenant_key FROM msgraph_connections WHERE id = #{connection.id}")

    assert raw["tenant_id"].present?
    assert_not_includes raw["tenant_id"], TENANT
    assert_not_includes raw["tenant_key"], TENANT
    assert_equal MsgraphConnection.tenant_key_for(TENANT), raw["tenant_key"]
    assert_equal TENANT, connection.reload.tenant_id
    assert_equal NOW, connection.connected_at
  end

  test "[unit] an inspect masks the tenant id and its key" do
    connection = store

    assert_not_includes connection.inspect, TENANT
    assert_not_includes connection.inspect, connection.tenant_key
    assert_includes connection.inspect, 'display_name: "Synthetic Org"' # the control: inspect does print this row
  end

  test "[unit] consenting the same tenant again updates its row, one row per tenant" do
    first = store(tenant_id: TENANT.upcase)
    second = store(display_name: "Renamed Org", now: NOW + 1.hour)
    store(tenant_id: OTHER_TENANT, display_name: "Other Org", now: NOW + 2.hours)

    assert_equal first.id, second.id
    assert_equal 2, MsgraphConnection.count
    assert_equal "Renamed Org", second.reload.display_name
    assert_equal %w[Other\ Org Renamed\ Org], MsgraphConnection.readable.map(&:display_name)
  end

  test "[unit] a tenant Graph did not name is stored under the label" do
    assert_equal MsgraphConnection::LABEL, store(display_name: "  ").display_name
  end

  test "[unit] a tenant id that is not a GUID is refused by field name, not value" do
    error = assert_raises(ActiveRecord::RecordInvalid) { store(tenant_id: "not-a-guid") }
    assert_match(/Tenant is invalid/, error.message)
    assert_no_match(/not-a-guid/, error.message)
    assert_equal 0, MsgraphConnection.count
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a row stored under another key is unreadable, skipped, and replaced by the next consent" do
    old = store
    assert old.readable? # the control
    assert_equal [ old ], MsgraphConnection.readable

    with_other_encryption_key do
      assert_not MsgraphConnection.find(old.id).readable?
      assert_empty MsgraphConnection.readable
      assert_no_difference -> { MsgraphConnection.count } do
        store(display_name: "Fresh", now: NOW + 1.hour)
      end
      row = MsgraphConnection.sole
      assert_not_equal old.id, row.id
      assert_equal TENANT, row.tenant_id
    end
  end
end
