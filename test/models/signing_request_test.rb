require "test_helper"

class SigningRequestTest < ActiveSupport::TestCase
  def build(**overrides)
    SigningRequest.create!({
      program: "turf_vault",
      program_id: "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ",
      cluster: "devnet",
      instruction_name: "update_signers",
      coordination: "multi",
      threshold: 2,
      expected_signers: %w[AAA BBB],
      status: "awaiting_signatures"
    }.merge(overrides))
  end

  test "gets a stable slug that does not churn across saves" do
    sr = build
    slug = sr.slug
    assert slug.present?
    sr.update!(title: "x")
    assert_equal slug, sr.reload.slug
  end

  test "records a signature from an expected signer and flips to fully_signed at threshold" do
    sr = build
    sr.record_signature!(pubkey: "AAA", signature_b64: "sigA")
    assert_equal "awaiting_signatures", sr.status
    assert_equal 1, sr.signatures_needed

    sr.record_signature!(pubkey: "BBB", signature_b64: "sigB")
    assert sr.threshold_met?
    assert_equal "fully_signed", sr.status
    assert_equal 0, sr.signatures_needed
    assert_equal %w[AAA BBB], sr.signers_signed.sort
  end

  test "rejects a signature from a non-expected signer" do
    sr = build
    assert_raises(ArgumentError) { sr.record_signature!(pubkey: "EVE", signature_b64: "x") }
  end

  test "single-signer request is fully signed by one signature" do
    sr = build(coordination: "single", threshold: 1, expected_signers: %w[AAA])
    sr.record_signature!(pubkey: "AAA", signature_b64: "sigA")
    assert sr.threshold_met?
    assert_equal "fully_signed", sr.status
  end

  test "mark_broadcast! and mark_failed! transitions" do
    sr = build
    sr.mark_broadcast!("txsig123")
    assert sr.broadcast?
    assert_equal "txsig123", sr.tx_signature

    sr2 = build
    sr2.mark_failed!("boom")
    assert_equal "failed", sr2.status
    assert_equal "boom", sr2.last_error
  end
end
