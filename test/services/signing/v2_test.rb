require "test_helper"

# v2 signing console — IDL registry, the program-agnostic builder (single-signer
# initialize + multi-signer durable-nonce update_signers), and the keyless
# signature Assembler.
class SigningV2Test < ActiveSupport::TestCase
  # --- IDL registry ---------------------------------------------------------

  test "IdlRegistry lists programs/clusters and loads an IDL" do
    assert_includes Signing::IdlRegistry.programs, "turf_vault"
    assert_equal %w[devnet mainnet], Signing::IdlRegistry.clusters_for("turf_vault").sort
    idl = Signing::IdlRegistry.idl(program: "turf_vault", cluster: "devnet")
    assert_equal "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ", idl.program_id
    assert_raises(Signing::IdlRegistry::UnknownProgram) { Signing::IdlRegistry.clusters_for("nope") }
  end

  # --- builder: update_signers (multi, keyless) -----------------------------

  test "update_signers_keyless encodes identical instruction bytes to v1 and expects both signers" do
    nonce = { pubkey: Solana::Keypair.generate.to_base58, authority: Signing::SigningRequest::MASON_CYT }
    v1 = Signing::SigningRequest.update_signers(cluster: "devnet")
    v2 = Signing::SigningRequest.update_signers_keyless(cluster: "devnet", durable_nonce: nonce)

    # Byte-match gate: the keyless variant must encode the SAME instruction data.
    assert_equal v1.instruction_data, v2.instruction_data
    assert_equal 2, v2.threshold
    assert_equal "multi", v2.coordination
    assert_equal [Signing::SigningRequest::MASON_CYT, Signing::SigningRequest::ALEX_7ZDJ], v2.expected_signers
  end

  test "discriminator is the pinned IDL value (correctness gate)" do
    sr = Signing::SigningRequest.update_signers(cluster: "devnet")
    assert_equal [228, 82, 68, 150, 92, 66, 140, 174].pack("C*").b, sr.instruction_data[0, 8]
  end

  # --- builder: initialize (single signer) ----------------------------------

  test "initialize_vault resolves all accounts incl. account-path PDA seeds + fixed addresses" do
    admin = Solana::Keypair.generate.to_base58
    signers = Array.new(3) { Solana::Keypair.generate.to_base58 }
    mint_a = Solana::Keypair.generate.to_base58
    mint_b = Solana::Keypair.generate.to_base58

    sr = Signing::SigningRequest.initialize_vault(
      cluster: "devnet", admin: admin, signers: signers, threshold: 2,
      treasury_authority: admin, payout_mint: mint_a, second_currency_mint: mint_b
    )
    assert_equal "single", sr.coordination
    assert_equal 1, sr.threshold
    assert_equal [admin], sr.expected_signers

    metas = sr.account_metas
    names = Signing::IdlRegistry.idl(program: "turf_vault", cluster: "devnet").accounts("initialize").map { |a| a["name"] }
    assert_equal names.length, metas.length

    # admin is signer+writable; token_program resolves to the pinned fixed address;
    # the op_rev ATAs derived (account-path seed) to valid base58 PDAs.
    assert metas[0][:is_signer]
    assert metas[0][:is_writable]
    token_idx = names.index("token_program")
    assert_equal "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", metas[token_idx][:pubkey]
    op_rev_idx = names.index("payout_op_rev_ata")
    assert metas[op_rev_idx][:pubkey].length.between?(32, 44) # base58 pubkey

    # instruction data = discriminator (initialize) + borsh(signers, threshold, treasury)
    assert_equal [175, 175, 109, 31, 13, 152, 155, 237].pack("C*").b, sr.instruction_data[0, 8]
  end

  # --- durable nonce: advance prepended + authority is a signer -------------

  test "a durable-nonce request prepends the System advance instruction" do
    nonce_pubkey = Solana::Keypair.generate.to_base58
    nonce_value  = Solana::Keypair.generate.to_base58
    sr = Signing::SigningRequest.update_signers_keyless(
      cluster: "devnet",
      durable_nonce: { pubkey: nonce_pubkey, authority: Signing::SigningRequest::MASON_CYT }
    )
    assert_equal "multi", sr.coordination
    assert sr.durable_nonce

    unsigned = sr.build_unsigned_message_base64(blockhash: nonce_value)
    raw = Base64.strict_decode64(unsigned).b
    # The System program id (32 zero bytes) is referenced only by the advance
    # instruction — its presence proves the advance was prepended.
    assert raw.include?("\x00".b * 32), "expected the System program (advance ix) in the tx"
    # The nonce authority (Mason) is one of the required signers.
    assert_includes Signing::Assembler.parse(unsigned)[:signer_pubkeys], Signing::SigningRequest::MASON_CYT
  end

  # --- Assembler round-trip (THE keyless correctness proof) -----------------

  test "Assembler reconstructs a fully-signed tx from collected public signatures" do
    kp1 = Solana::Keypair.generate
    kp2 = Solana::Keypair.generate
    blockhash = Solana::Keypair.generate.to_base58 # any 32-byte base58 stands in
    new_signers = Array.new(3) { Solana::Keypair.generate.to_base58 }

    sr = Signing::SigningRequest.new(
      cluster: "devnet",
      instruction_name: "update_signers",
      args: { "new_signers" => new_signers },
      accounts: { "admin" => kp1.to_base58, "cosigner" => kp2.to_base58, "vault_state" => :pda },
      expected_signers: [kp1.to_base58, kp2.to_base58],
      threshold: 2,
      fee_payer: kp1.to_base58
    )

    unsigned = sr.build_unsigned_message_base64(blockhash: blockhash)
    message  = Signing::Assembler.message_for(unsigned)

    collected = {
      kp1.to_base58 => Base64.strict_encode64(kp1.sign(message)),
      kp2.to_base58 => Base64.strict_encode64(kp2.sign(message))
    }
    assembled = Signing::Assembler.assemble(unsigned, collected)

    # Ground truth: the same tx signed directly by both keypairs.
    truth = Solana::Transaction.new
    truth.set_recent_blockhash(blockhash)
    truth.add_signer(kp1)
    truth.add_signer(kp2)
    truth.add_instruction(program_id: sr.program_id, accounts: sr.account_metas, data: sr.instruction_data)

    assert_equal truth.serialize_base64, assembled
  end

  test "Assembler refuses to assemble with a missing required signature" do
    kp1 = Solana::Keypair.generate
    kp2 = Solana::Keypair.generate
    sr = Signing::SigningRequest.new(
      cluster: "devnet", instruction_name: "update_signers",
      args: { "new_signers" => Array.new(3) { Solana::Keypair.generate.to_base58 } },
      accounts: { "admin" => kp1.to_base58, "cosigner" => kp2.to_base58, "vault_state" => :pda },
      expected_signers: [kp1.to_base58, kp2.to_base58], threshold: 2, fee_payer: kp1.to_base58
    )
    unsigned = sr.build_unsigned_message_base64(blockhash: Solana::Keypair.generate.to_base58)
    message  = Signing::Assembler.message_for(unsigned)
    only_one = { kp1.to_base58 => Base64.strict_encode64(kp1.sign(message)) }
    assert_raises(ArgumentError) { Signing::Assembler.assemble(unsigned, only_one) }
  end
end
