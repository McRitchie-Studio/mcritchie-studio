class CreateArenas < ActiveRecord::Migration[7.2]
  def change
    create_table :arenas do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :address
      t.string :location
      t.string :city
      t.string :state
      t.string :country
      t.string :timezone

      t.timestamps null: false

      t.index :slug, unique: true
    end
  end
end
