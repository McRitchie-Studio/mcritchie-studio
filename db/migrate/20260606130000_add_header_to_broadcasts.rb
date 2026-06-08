class AddHeaderToBroadcasts < ActiveRecord::Migration[7.2]
  def change
    add_column :broadcasts, :header, :string     # email title band (e.g. "It's almost here")
    add_column :broadcasts, :subheader, :string  # sub-line under the title
  end
end
