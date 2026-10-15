# Where each registered report (config/report_destinations.yml) is delivered, and
# a receipt per delivery (docs/agents/system/report-destinations.md).
# report_deliveries.idempotency_key is unique: ReportDestinations.deliver posts a
# key at most once.
class CreateReportDestinations < ActiveRecord::Migration[8.1]
  def change
    create_table :report_destinations do |t|
      t.string :report_key, null: false
      t.references :discord_channel, foreign_key: { on_delete: :nullify }
      t.boolean :enabled, null: false, default: true
      t.string :updated_by
      t.timestamps
    end
    add_index :report_destinations, :report_key, unique: true

    create_table :report_deliveries do |t|
      t.string :report_key, null: false
      t.string :idempotency_key, null: false
      t.references :discord_channel, foreign_key: { on_delete: :nullify }
      t.string :guild_external_id
      t.string :channel_external_id
      t.string :message_external_id
      t.string :status, null: false
      t.text :error
      t.datetime :posted_at
      t.timestamps
    end
    add_index :report_deliveries, :idempotency_key, unique: true
    add_index :report_deliveries, [ :report_key, :created_at ]
  end
end
