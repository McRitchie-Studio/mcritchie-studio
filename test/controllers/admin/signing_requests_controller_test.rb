require "test_helper"
require "minitest/mock"

class Admin::SigningRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = users(:alex)    # role: admin
    @viewer = users(:viewer)
  end

  test "index requires admin" do
    get admin_signing_requests_path
    assert_response :redirect # not logged in → login

    log_in_as(@viewer)
    get admin_signing_requests_path
    assert_redirected_to root_path # non-admin bounced
  end

  test "admin can view the queue" do
    log_in_as(@admin)
    get admin_signing_requests_path
    assert_response :success
  end

  test "create builds a multi-signer update_signers request over a durable nonce" do
    log_in_as(@admin)
    nonce_value = Solana::Keypair.generate.to_base58

    Signing::Rpc.stub(:nonce_value, nonce_value) do
      assert_difference "SigningRequest.count", 1 do
        post admin_signing_requests_path, params: {
          template: "update_signers", cluster: "devnet",
          nonce_pubkey: Solana::Keypair.generate.to_base58,
          nonce_authority: Signing::SigningRequest::MASON_CYT
        }
      end
    end

    sr = SigningRequest.last
    assert_equal "multi", sr.coordination
    assert_equal 2, sr.threshold
    assert_equal "update_signers", sr.instruction_name
    assert sr.unsigned_message_base64.present?
    assert_redirected_to admin_signing_request_path(sr)
  end

  # Build a real keyless request whose signers are generated keypairs so we can
  # produce a verifiable signature, then drive submit_signature → broadcast.
  def keyless_request
    @kp1 = Solana::Keypair.generate
    @kp2 = Solana::Keypair.generate
    builder = Signing::SigningRequest.new(
      cluster: "devnet", instruction_name: "update_signers",
      args: { "new_signers" => Array.new(3) { Solana::Keypair.generate.to_base58 } },
      accounts: { "admin" => @kp1.to_base58, "cosigner" => @kp2.to_base58, "vault_state" => :pda },
      expected_signers: [@kp1.to_base58, @kp2.to_base58], threshold: 2, fee_payer: @kp1.to_base58
    )
    unsigned = builder.build_unsigned_message_base64(blockhash: Solana::Keypair.generate.to_base58)
    SigningRequest.create!(
      title: "test", program: "turf_vault", program_id: builder.program_id, cluster: "devnet",
      instruction_name: "update_signers", coordination: "multi", threshold: 2,
      expected_signers: [@kp1.to_base58, @kp2.to_base58], unsigned_message_base64: unsigned
    )
  end

  test "submit_signature verifies + records a real ed25519 signature" do
    log_in_as(@admin)
    sr = keyless_request
    message = Signing::Assembler.message_for(sr.unsigned_message_base64)
    sig_b64 = Base64.strict_encode64(@kp1.sign(message))

    post submit_signature_admin_signing_request_path(sr),
         params: { signer: @kp1.to_base58, signature: sig_b64 }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert sr.reload.signed_by?(@kp1.to_base58)
  end

  test "submit_signature rejects a forged signature" do
    log_in_as(@admin)
    sr = keyless_request
    bogus = Base64.strict_encode64("\x00" * 64)
    post submit_signature_admin_signing_request_path(sr),
         params: { signer: @kp1.to_base58, signature: bogus }, as: :json
    assert_response :unprocessable_entity
    assert_not sr.reload.signed_by?(@kp1.to_base58)
  end

  test "broadcast refuses until threshold met, then submits the assembled tx" do
    log_in_as(@admin)
    sr = keyless_request
    message = Signing::Assembler.message_for(sr.unsigned_message_base64)

    # Not enough signatures yet → refused.
    post broadcast_admin_signing_request_path(sr)
    assert_redirected_to admin_signing_request_path(sr)
    assert_not sr.reload.broadcast?

    # Collect both real signatures, then broadcast (RPC stubbed).
    sr.record_signature!(pubkey: @kp1.to_base58, signature_b64: Base64.strict_encode64(@kp1.sign(message)))
    sr.record_signature!(pubkey: @kp2.to_base58, signature_b64: Base64.strict_encode64(@kp2.sign(message)))

    Signing::Rpc.stub(:forward, [200, { result: "TXSIG123" }.to_json]) do
      post broadcast_admin_signing_request_path(sr)
    end
    assert_equal "broadcast", sr.reload.status
    assert_equal "TXSIG123", sr.tx_signature
  end
end
