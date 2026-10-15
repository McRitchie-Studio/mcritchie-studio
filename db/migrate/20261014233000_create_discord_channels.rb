# The Discord channel directory (docs/agents/system/report-destinations.md): every
# channel and active thread the agents' bot can see in each configured guild,
# mirrored by DiscordChannelSyncJob. A channel the sync no longer sees is
# archived (archived_at), never deleted, so a destination never dangles.
class CreateDiscordChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :discord_channels do |t|
      t.string :guild_external_id, null: false
      t.string :external_id, null: false
      t.string :name, null: false
      t.string :kind, null: false
      t.string :parent_external_id
      t.string :category_name
      t.integer :position
      t.boolean :postable, null: false, default: false
      t.datetime :archived_at
      t.datetime :synced_at
      t.timestamps
    end
    add_index :discord_channels, [ :guild_external_id, :external_id ], unique: true
    add_index :discord_channels, :archived_at
  end
end
