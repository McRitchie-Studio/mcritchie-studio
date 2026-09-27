# The email analytics event log (task email-event-log-webhooks): one row per
# thing that happens to a broadcast email, from Resend's webhooks, our own open
# pixel and click redirect, and the unsubscribe page. The delivery row keeps the
# first time of each so the dashboard reads rollups, not the whole log.
class CreateEmailEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :email_events do |t|
      t.references :broadcast_delivery, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :source, null: false
      t.boolean :machine, null: false, default: false
      t.string :link_key
      t.string :provider_event_id
      t.datetime :occurred_at, null: false
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_index :email_events, [:broadcast_delivery_id, :kind]
    add_index :email_events, :occurred_at
    add_index :email_events, :provider_event_id, unique: true, where: "provider_event_id IS NOT NULL"

    change_table :broadcast_deliveries, bulk: true do |t|
      t.string :provider_message_id
      t.datetime :delivered_at
      t.datetime :bounced_at
      t.string :bounce_kind
      t.datetime :complained_at
      t.datetime :unsubscribed_at
      t.datetime :human_opened_at
      t.datetime :human_clicked_at
    end
    add_index :broadcast_deliveries, :provider_message_id, unique: true, where: "provider_message_id IS NOT NULL"

    add_column :contacts, :unsubscribe_reason, :string
  end
end
