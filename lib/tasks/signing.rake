namespace :signing do
  # Create + initialize a durable nonce account and register it as a DurableNonce.
  #
  #   SOLANA_NONCE_PAYER_KEY=<base58 secret> \
  #     bin/rails "signing:create_nonce_account[devnet,7ZDJp7FUHhuce…,mcritchie-ops]"
  #
  # The fee payer key is read from ENV at RUN TIME ONLY and never persisted — it
  # funds the ~0.0015 SOL rent. The nonce-account keypair is generated here and
  # signs creation once; thereafter the account is controlled by `authority`
  # (a Phantom signer), not by that keypair. So no signer key lives on the server.
  #
  # Pure-no-key alternative (operator's local CLI keypair as payer):
  #   solana-keygen new -o /tmp/nonce.json --no-bip39-passphrase
  #   solana create-nonce-account /tmp/nonce.json 0.0015 \
  #     --nonce-authority <AUTHORITY_PUBKEY> --url devnet
  #   bin/rails "signing:register_nonce[devnet,<NONCE_PUBKEY>,<AUTHORITY>,label]"
  desc "Create + initialize a durable nonce account and register it (args: cluster, authority, [label])"
  task :create_nonce_account, %i[cluster authority label] => :environment do |_t, args|
    cluster   = (args[:cluster].presence || "devnet").to_s
    authority = args[:authority].presence or abort "authority pubkey required (a Phantom signer)"
    label     = args[:label].presence

    secret = ENV["SOLANA_NONCE_PAYER_KEY"].presence or
      abort "Set SOLANA_NONCE_PAYER_KEY (base58 secret of a funded payer) for this run."
    payer    = Solana::Keypair.from_base58(secret)
    nonce_kp = Solana::Keypair.generate

    rent      = Signing::Rpc.min_balance_for_rent_exemption(cluster, Solana::SystemProgram::NONCE_ACCOUNT_LENGTH)
    blockhash = Signing::Rpc.latest_blockhash(cluster)

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(blockhash)
    tx.add_signer(payer)
    tx.add_signer(nonce_kp)

    create_ix = Solana::SystemProgram.create_account(
      from: payer, new_account: nonce_kp, lamports: rent,
      space: Solana::SystemProgram::NONCE_ACCOUNT_LENGTH, owner: Solana::Transaction::SYSTEM_PROGRAM_ID
    )
    init_ix = Solana::SystemProgram.initialize_nonce_account(nonce: nonce_kp, authority: authority)
    [create_ix, init_ix].each { |ix| tx.add_instruction(program_id: ix[:program_id], accounts: ix[:accounts], data: ix[:data]) }

    sig = Signing::Rpc.send_transaction(cluster, tx.serialize_base64)
    record = DurableNonce.create!(pubkey: nonce_kp.to_base58, authority: authority, cluster: cluster, label: label)

    puts "Created nonce account #{record.pubkey} (authority #{authority}) on #{cluster}"
    puts "  tx: #{sig}"
    puts "  registered DurableNonce ##{record.id} (#{record.slug})"
  end

  # Register an already-created nonce account (e.g. made via the solana CLI).
  desc "Register an existing durable nonce account (args: cluster, pubkey, authority, [label])"
  task :register_nonce, %i[cluster pubkey authority label] => :environment do |_t, args|
    cluster   = (args[:cluster].presence || "devnet").to_s
    pubkey    = args[:pubkey].presence    or abort "nonce pubkey required"
    authority = args[:authority].presence or abort "authority pubkey required"

    # Verify on-chain before registering: must be an initialized nonce account
    # owned by the claimed authority.
    Signing::Rpc.nonce_value(cluster, pubkey, expected_authority: authority)
    record = DurableNonce.create!(pubkey: pubkey, authority: authority, cluster: cluster, label: args[:label].presence)
    puts "Registered DurableNonce ##{record.id} (#{record.pubkey}) on #{cluster}"
  end
end
