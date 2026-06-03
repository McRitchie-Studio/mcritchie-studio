require "test_helper"

class SolanaSessionsControllerTest < ActionDispatch::IntegrationTest
  test "nonce returns a fresh nonce" do
    get solana_nonce_path
    assert_response :success
    assert JSON.parse(response.body)["nonce"].present?
  end

  test "verify rejects a bogus signature" do
    get solana_nonce_path # seed a nonce into the session
    post solana_verify_path, params: { message: "x", signature: "y", pubkey: "z" }
    assert_includes [401, 422], response.status
    assert JSON.parse(response.body)["error"].present?
  end
end
