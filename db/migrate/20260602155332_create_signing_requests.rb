class CreateSigningRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :signing_requests do |t|
      t.string  :slug, null: false
      t.string  :title
      t.string  :program, null: false, default: "turf_vault"  # IDL registry key
      t.string  :program_id, null: false                       # on-chain address (pinned)
      t.string  :cluster, null: false, default: "devnet"
      t.string  :instruction_name, null: false
      t.jsonb   :args, null: false, default: {}
      t.jsonb   :accounts, null: false, default: {}

      # Signer topology. `single` = one human wallet (e.g. initialize's
      # INIT_AUTHORITY), fresh blockhash, no coordination. `multi` = N wallets
      # signing in separate browsers, coordinated over a durable nonce.
      t.string  :coordination, null: false, default: "multi"
      t.integer :threshold, null: false, default: 1
      t.string  :expected_signers, array: true, null: false, default: []
      t.jsonb   :collected_signatures, null: false, default: {} # pubkey => base64 signature

      t.string  :multisig_pubkey      # the multisig PDA/account, when applicable
      t.string  :fee_payer

      # Durable nonce (multi only): the nonce account + its authority, and the
      # nonce value baked into the unsigned message so a half-signed tx never
      # expires between signers.
      t.string  :durable_nonce_pubkey
      t.string  :nonce_authority

      # The exact unsigned transaction the signers sign (base64). Server holds
      # only this + the public collected signatures — never a key.
      t.text    :unsigned_message_base64

      t.string  :status, null: false, default: "awaiting_signatures"
      t.string  :tx_signature
      t.text    :last_error

      t.timestamps
    end

    add_index :signing_requests, :slug, unique: true
    add_index :signing_requests, :status
  end
end
