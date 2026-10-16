# Which CTO souls' OWN Discord bots can post a report in this channel: View
# Channel, Send Messages and Embed Links, read by DiscordDirectory::Sync from the
# guild's roles and the channel's overwrites for each soul whose
# DISCORD_BOT_TOKEN_<SOUL> is set (docs/agents/system/app-owners.md). The owner's
# channel picker reads it, so a page load never calls Discord.
class AddPostableSoulsToDiscordChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :discord_channels, :postable_souls, :string, array: true, default: [], null: false
  end
end
