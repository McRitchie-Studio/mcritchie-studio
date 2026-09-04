# The admin signing console was retired on 2026-09-04
# (/tasks/retire-signing-console): Turf Monster is the hub for all Solana/web3
# logic, so the hub keeps none. Measured against production the same day before
# this ran — SigningRequest.count => 0, DurableNonce.pluck(:cluster).tally =>
# {"devnet" => 1} — so the only row lost is one devnet nonce account, whose
# on-chain pubkey outlives this table and was never referenced by anything else.
#
# Reversible on purpose: `down` rebuilds both tables exactly as schema.rb
# declared them, so a rollback restores the shape (never the rows).
class DropSigningConsoleTables < ActiveRecord::Migration[8.1]
  def up
    drop_table :signing_requests
    drop_table :durable_nonces
  end

  def down
    create_table :durable_nonces do |t|
      t.string :authority, null: false
      t.string :cluster, default: "devnet", null: false
      t.string :label
      t.string :pubkey, null: false
      t.string :slug, null: false
      t.string :status, default: "active", null: false
      t.timestamps
      t.index %i[cluster status]
      t.index :pubkey, unique: true
      t.index :slug, unique: true
    end

    create_table :signing_requests do |t|
      t.jsonb :accounts, default: {}, null: false
      t.jsonb :args, default: {}, null: false
      t.string :cluster, default: "devnet", null: false
      t.jsonb :collected_signatures, default: {}, null: false
      t.string :coordination, default: "multi", null: false
      t.string :durable_nonce_pubkey
      t.string :expected_signers, default: [], null: false, array: true
      t.string :fee_payer
      t.string :instruction_name, null: false
      t.text :last_error
      t.string :multisig_pubkey
      t.string :nonce_authority
      t.string :program, default: "turf_vault", null: false
      t.string :program_id, null: false
      t.string :slug, null: false
      t.string :status, default: "awaiting_signatures", null: false
      t.integer :threshold, default: 1, null: false
      t.string :title
      t.string :tx_signature
      t.text :unsigned_message_base64
      t.timestamps
      t.index :slug, unique: true
      t.index :status
    end
  end
end
