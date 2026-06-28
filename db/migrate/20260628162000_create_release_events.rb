class CreateReleaseEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :release_events do |t|
      t.string :release_slug, null: false
      t.string :step, null: false
      t.string :status, null: false
      t.string :source
      t.string :actor
      t.string :model
      t.integer :tokens_in
      t.integer :tokens_out
      t.decimal :cost, precision: 10, scale: 4
      t.string :repo
      t.string :app
      t.string :sha
      t.string :url
      t.string :command
      t.text :message
      t.string :idempotency_key
      t.jsonb :metadata, default: {}, null: false
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :release_events, [:release_slug, :occurred_at]
    add_index :release_events, [:release_slug, :step, :status]
    add_index :release_events, [:release_slug, :idempotency_key],
              unique: true,
              where: "idempotency_key IS NOT NULL"
  end
end
