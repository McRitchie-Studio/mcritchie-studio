require "test_helper"

module Signing
  class SigningRequestTest < ActiveSupport::TestCase
    # ---- THE CORRECTNESS GATE ------------------------------------------------
    # The Ruby-encoded update_signers instruction data MUST byte-match Jasper's
    # proven JS tx (decoded from /tmp/update_signers_unsigned.b64 on 2026-06-02).
    # A wrong encoding signs a wrong signer rotation. Do not weaken this test.
    PROVEN_IX_DATA_HEX =
      "e45244965c428cae" \
      "6ca63236879959d39295fa0bdc15495abe61f71309f9f6445960899dc9aa5212" \
      "61669f860487f726195078deeef47ef07f93a53e611bdda63a182328404f2fc7" \
      "b203165301e10fcaece25552dd427362a1def717b2543399b6ecf5495998f6e2"

    test "update_signers instruction data byte-matches the proven JS tx" do
      sr = SigningRequest.update_signers(cluster: "devnet")
      assert_equal PROVEN_IX_DATA_HEX, sr.instruction_data.unpack1("H*"),
                   "Ruby Borsh encoding drifted from the proven update_signers bytes"
    end

    test "update_signers discriminator is the Anchor global hash" do
      sr = SigningRequest.update_signers(cluster: "devnet")
      assert_equal "e45244965c428cae", sr.instruction_data[0, 8].unpack1("H*")
    end

    test "update_signers ix data is 104 bytes (8 disc + 3x32 pubkey)" do
      sr = SigningRequest.update_signers(cluster: "devnet")
      assert_equal 104, sr.instruction_data.bytesize
    end

    test "devnet program id is the EQGF program" do
      sr = SigningRequest.update_signers(cluster: "devnet")
      assert_equal "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ", sr.program_id
    end

    test "mainnet variant uses the mainnet program id, same ix bytes" do
      dev  = SigningRequest.update_signers(cluster: "devnet")
      main = SigningRequest.update_signers(cluster: "mainnet")
      assert_equal "mnzowM2F9dppGVFGrcTAh5351mMqYunX3b2MvdvgS2S", main.program_id
      assert_equal dev.instruction_data, main.instruction_data
    end

    test "account metas resolve in IDL order with vault_state PDA derived" do
      sr = SigningRequest.update_signers(cluster: "devnet")
      metas = sr.account_metas
      assert_equal 3, metas.length
      # admin (Mason) signer + writable
      assert_equal SigningRequest::MASON_CYT, metas[0][:pubkey]
      assert metas[0][:is_signer] && metas[0][:is_writable]
      # cosigner (Alex) signer, readonly
      assert_equal SigningRequest::ALEX_7ZDJ, metas[1][:pubkey]
      assert metas[1][:is_signer]
      refute metas[1][:is_writable]
      # vault_state PDA, derived [b"vault"], non-signer + writable
      refute metas[2][:is_signer]
      assert metas[2][:is_writable]
      assert_equal "J7b5g9uS5M2Nog1Ly1UATXTDMtXdpXK3JffRAHXGHkK2", metas[2][:pubkey]
    end

  end

  class ArgEncoderTest < ActiveSupport::TestCase
    test "fixed array of pubkey encodes with no length prefix" do
      schema = [{ "name" => "new_signers", "type" => { "array" => ["pubkey", 3] } }]
      pks = SigningRequest::NEW_SIGNERS
      bytes = ArgEncoder.encode(schema, "new_signers" => pks)
      assert_equal 96, bytes.bytesize
    end

    test "unsupported type raises rather than guessing" do
      schema = [{ "name" => "x", "type" => "f64" }]
      assert_raises(ArgEncoder::UnsupportedType) { ArgEncoder.encode(schema, "x" => 1.0) }
    end
  end
end
