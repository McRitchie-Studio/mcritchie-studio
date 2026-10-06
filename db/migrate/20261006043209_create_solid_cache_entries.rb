# Solid Cache's table, in the primary database. The body is the schema
# `bin/rails solid_cache:install` (solid_cache 1.0.10) writes to
# db/cache_schema.rb for a separate cache database; the hub keeps one database,
# as it does for Solid Queue, so the table arrives through a migration and the
# Heroku release phase's db:migrate. Rack::Attack keeps its throttle counters
# here (config/initializers/rack_attack.rb).
class CreateSolidCacheEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :solid_cache_entries do |t|
      t.binary :key, limit: 1024, null: false
      t.binary :value, limit: 536870912, null: false
      t.datetime :created_at, null: false
      t.integer :key_hash, limit: 8, null: false
      t.integer :byte_size, limit: 4, null: false

      t.index [ :byte_size ], name: "index_solid_cache_entries_on_byte_size"
      t.index [ :key_hash, :byte_size ], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
      t.index [ :key_hash ], name: "index_solid_cache_entries_on_key_hash", unique: true
    end
  end
end
