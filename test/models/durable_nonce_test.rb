require "test_helper"

class DurableNonceTest < ActiveSupport::TestCase
  def build(**over)
    DurableNonce.create!({
      pubkey: Solana::Keypair.generate.to_base58,
      authority: Signing::SigningRequest::MASON_CYT,
      cluster: "devnet"
    }.merge(over))
  end

  test "gets a stable slug" do
    n = build
    slug = n.slug
    n.update!(label: "ops")
    assert_equal slug, n.reload.slug
  end

  test "pubkey is unique" do
    n = build
    dup = DurableNonce.new(pubkey: n.pubkey, authority: "x", cluster: "devnet")
    assert_not dup.valid?
  end

  test "active_for returns the active nonce for a cluster" do
    a = build(cluster: "devnet")
    build(cluster: "mainnet")
    build(cluster: "devnet", status: "retired")
    assert_equal a.id, DurableNonce.active_for("devnet").id
    assert_nil DurableNonce.active_for("nope")
  end
end
