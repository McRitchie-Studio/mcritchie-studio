# The legacy-use census: one row per day, endpoint and caller for requests the
# shared secret authenticated, with a counter. A new table; no existing row is
# read or written.
class CreateLegacyAuthUses < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_auth_uses do |t|
      t.date :day, null: false
      t.string :endpoint, null: false
      t.string :caller, null: false
      t.integer :uses, null: false, default: 0
      t.datetime :last_used_at, null: false
    end
    add_index :legacy_auth_uses, %i[day endpoint caller], unique: true
  end
end
