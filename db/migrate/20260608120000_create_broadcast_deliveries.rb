class CreateBroadcastDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :broadcast_deliveries do |t|
      t.references :broadcast, null: false, foreign_key: true
      t.references :contact, null: false, foreign_key: true
      t.string :token, null: false           # opaque id used in pixel + click URLs
      t.datetime :sent_at
      t.datetime :opened_at                  # first open
      t.integer :open_count, null: false, default: 0
      t.datetime :clicked_at                 # first click
      t.integer :click_count, null: false, default: 0

      t.timestamps
    end

    add_index :broadcast_deliveries, :token, unique: true
    add_index :broadcast_deliveries, %i[broadcast_id contact_id], unique: true
  end
end
