class CreateBroadcasts < ActiveRecord::Migration[7.2]
  def change
    create_table :broadcasts do |t|
      t.string :slug, null: false
      t.string :subject, null: false, default: ""
      t.string :preview_text
      t.string :template_key, null: false        # view under app/views/broadcasts/
      t.string :status, null: false, default: "draft"  # draft | sent
      t.string :target_list                       # HubSpot list name (for the operator)
      t.string :survivor_url                      # fills {{SURVIVOR_URL}} in the template
      t.string :turf_totals_url                   # fills {{TURF_TOTALS_URL}}
      t.datetime :sent_at

      t.timestamps
    end

    add_index :broadcasts, :slug, unique: true
    add_index :broadcasts, :status
  end
end
