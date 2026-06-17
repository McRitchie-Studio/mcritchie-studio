class AddHeroUrlToBroadcasts < ActiveRecord::Migration[7.2]
  def change
    add_column :broadcasts, :hero_url, :string # makes the header image a clickable link
  end
end
