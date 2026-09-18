require "test_helper"

# [unit] The 1Password guard armed in test_helper.rb.
#
# A guard nothing proves is a guard nobody can trust, and this one is cheap to
# fool into silence: if the fake never lands on PATH, every test passes and the
# suite quietly spends the shared, account-wide daily quota that the ship lane
# also draws on. So this file exercises the fake DIRECTLY.
class OpGuardTest < ActiveSupport::TestCase
  test "the op on PATH inside the suite is the fake, not the real CLI" do
    which = `which op`.strip

    assert_equal Rails.root.join("test/support/bin/op").to_s, which,
      "the real 1Password CLI must be unreachable from the suite"
  end

  test "a call to op is RECORDED, which is what lets the teardown name the caller" do
    calls = reaching_fake_op { system("op", "read", "op://synthetic/item/field", out: File::NULL, err: File::NULL) }

    assert_equal 1, calls.size
    assert_includes calls.first[:argv], "op://synthetic/item/field"
  end

  test "the fake FAILS the read rather than returning something token-shaped" do
    # It prints to stdout on purpose: a caller that trusts output over the exit
    # status reads that line as a token, and this is what catches it.
    output = nil
    status = nil
    reaching_fake_op do
      output = `op read op://synthetic/item/field 2>/dev/null`
      status = $?.exitstatus
    end

    refute_equal 0, status, "a successful read would let a caller proceed on a fake token"
    # It must NAME ITSELF. A length/charset heuristic cannot tell a marker from
    # a secret — the shipped marker is 30 hyphenated word characters and my
    # first attempt at this assertion flagged it as credential-shaped — so the
    # checkable property is that anything reading it can see what it is.
    assert_match(/fake/i, output, "the marker must identify itself to whoever reads it")
    assert_match(/fail/i, output)
  end

  test "the service-account token is removed, so even a dodged call has no quota" do
    assert_nil ENV["OP_SERVICE_ACCOUNT_TOKEN"]
  end

  test "both credential modules are stubbed, so neither reaches the CLI unasked" do
    # The teardown guard would fail this test if either of these shelled out.
    refute Gmail::Credentials.configured?
    refute Workspace::Credentials.configured?
  end

  test "a deliberate call is not charged against the guard" do
    # reaching_fake_op drains the log, so the teardown sees nothing. If it did
    # not, this very test would fail — which is the point of asserting it here.
    reaching_fake_op { system("op", "--version", out: File::NULL, err: File::NULL) }

    assert_empty drain_fake_op_calls
  end
end
