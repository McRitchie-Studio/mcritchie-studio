class CreateDurableNonces < ActiveRecord::Migration[7.2]
  def change
    create_table :durable_nonces do |t|
      t.string :slug,      null: false
      t.string :pubkey,    null: false           # the nonce account address
      t.string :authority, null: false           # who signs nonceAdvance (a Phantom signer / managed wallet)
      t.string :cluster,   null: false, default: "devnet"
      t.string :status,    null: false, default: "active"  # active | retired
      t.string :label
      t.timestamps
    end
    add_index :durable_nonces, :slug,   unique: true
    add_index :durable_nonces, :pubkey, unique: true
    add_index :durable_nonces, [:cluster, :status]
  end
end
