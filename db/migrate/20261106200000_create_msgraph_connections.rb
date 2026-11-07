# The Microsoft 365 tenants the hub reads through Microsoft Graph, app-only,
# stored by the admin-consent callback itself (/admin/msgraph/callback). One
# row per tenant. The tenant id is encrypted at rest by the model (Active
# Record Encryption), so its column holds ciphertext; `tenant_key` is a keyed
# digest of the id (MsgraphConnection.tenant_key_for), unique, so a tenant
# consented twice keeps one row without the id ever being stored in the clear.
# No token is stored: the client-credentials token lives in process memory
# only. A new table: no existing row is read or written, and no data step is owed.
class CreateMsgraphConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :msgraph_connections do |t|
      t.text :tenant_id, null: false
      t.string :tenant_key, null: false
      t.string :display_name, null: false
      t.string :connected_by
      t.datetime :connected_at, null: false
      t.timestamps
    end
    add_index :msgraph_connections, :tenant_key, unique: true
    add_index :msgraph_connections, :connected_at
  end
end
