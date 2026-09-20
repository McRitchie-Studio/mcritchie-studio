require "test_helper"

# [unit] WorkspaceAccount — the allow-list that decides whose mailbox this
# system may open, and the convention that keeps one client's row from ever
# naming another client's user.
class WorkspaceAccountTest < ActiveSupport::TestCase
  test "the subject defaults to the team@ convention" do
    assert_equal "team@mason.test", WorkspaceAccount.create!(domain: "mason.test").subject
  end

  test "domain and subject normalize, so casing and spaces cannot fork a row" do
    a = WorkspaceAccount.create!(domain: "  Mason.TEST ")
    assert_equal "mason.test", a.domain
    assert_equal "team@mason.test", a.subject
  end

  test "a subject MUST belong to its own domain" do
    # The cross-tenant mistake, made impossible: a client's row can never be
    # pointed at another company's mailbox.
    bad = WorkspaceAccount.new(domain: "mason.test", subject: "team@somewhere-else.test")

    refute bad.valid?
    assert_match(/must be an address in mason.test/, bad.errors[:subject].first)
  end

  test "a different local part in the same domain is allowed" do
    assert WorkspaceAccount.new(domain: "mason.test", subject: "ops@mason.test").valid?
  end

  test "one row per domain, and one row per subject" do
    WorkspaceAccount.create!(domain: "mason.test")
    refute WorkspaceAccount.new(domain: "mason.test").valid?
  end

  test "a new workspace starts pending — registering is not authorization" do
    account = WorkspaceAccount.create!(domain: "mason.test")

    assert_equal "pending", account.status
    refute account.active?
    refute WorkspaceAccount.impersonatable?("team@mason.test")
  end

  test "verifying flips it active and clears the last refusal" do
    account = WorkspaceAccount.create!(domain: "mason.test")
    account.mark_unverified!("unauthorized_client")
    assert_equal "unauthorized_client", account.last_check_error

    account.mark_verified!
    assert account.active?
    assert account.delegation_verified_at
    assert_nil account.last_check_error
    assert WorkspaceAccount.impersonatable?("team@mason.test")
  end

  test "a refusal records WHY — the two causes need different responses" do
    # unauthorized_client is the normal not-yet state for a fresh grant, AND
    # what a grant placed in the wrong workspace looks like forever. Keeping the
    # reason is what lets a human tell them apart.
    account = WorkspaceAccount.create!(domain: "mason.test")
    account.mark_verified!
    account.mark_unverified!("unauthorized_client")

    assert_equal "pending", account.status
    refute WorkspaceAccount.impersonatable?("team@mason.test")
    assert_equal "unauthorized_client", account.last_check_error
  end

  test "a revoked workspace stays revoked through a failed check" do
    # Deliberately switched off must not drift back to merely "pending".
    account = WorkspaceAccount.create!(domain: "mason.test", status: "revoked")
    account.mark_unverified!("unauthorized_client")

    assert_equal "revoked", account.status
  end

  test "impersonatable? is case- and space-insensitive about the subject" do
    WorkspaceAccount.create!(domain: "mason.test").mark_verified!

    assert WorkspaceAccount.impersonatable?("  TEAM@Mason.test ")
    refute WorkspaceAccount.impersonatable?("team@other.test")
  end

  test "status is constrained" do
    assert_raises(ActiveRecord::RecordInvalid) { WorkspaceAccount.create!(domain: "m.test", status: "live") }
  end

  test "mark_verified! REFUSES to resurrect a revoked row" do
    # The blocker, at the model. The sweep no longer probes revoked rows, but
    # that is the other half — this is the one that holds for a caller which
    # does not exist yet. The rake task was exactly such a caller.
    account = WorkspaceAccount.create!(domain: "mason.test", status: "revoked")

    error = assert_raises(WorkspaceAccount::Revoked) { account.mark_verified! }

    assert_includes error.message, "reinstate"
    assert_equal "revoked", account.reload.status
    assert_nil account.delegation_verified_at
    refute WorkspaceAccount.impersonatable?("team@mason.test")
  end

  test "revoke! switches an ACTIVE workspace off and keeps the row" do
    account = WorkspaceAccount.create!(domain: "mason.test")
    account.mark_verified!
    assert WorkspaceAccount.impersonatable?("team@mason.test")

    account.revoke!("key exposed in a transcript")

    assert_equal "revoked", account.reload.status
    refute WorkspaceAccount.impersonatable?("team@mason.test")
    assert_includes account.notes, "key exposed in a transcript"
    assert WorkspaceAccount.exists?(domain: "mason.test"), "the row is kept, not destroyed"
  end

  test "reinstate! returns a revoked row to PENDING, never straight to active" do
    # Reinstating does not restore access. It only makes the grant provable
    # again, so coming back from a kill switch always costs two acts: a human
    # naming the domain, then a real token.
    account = WorkspaceAccount.create!(domain: "mason.test")
    account.mark_verified!
    account.revoke!

    account.reinstate!

    assert_equal "pending", account.reload.status
    refute WorkspaceAccount.impersonatable?("team@mason.test")
    assert_nil account.delegation_verified_at, "a reinstated row is no longer PROVEN"
  end

  test "reinstate! refuses a row that was never revoked" do
    account = WorkspaceAccount.create!(domain: "mason.test")

    assert_raises(ArgumentError) { account.reinstate! }
    assert_equal "pending", account.reload.status
  end

  test "a subject carrying two addresses is refused" do
    # "team@evil.test@mason.test" ends with the right domain and is still two
    # addresses. The mailbox would be this domain's either way, so this closes
    # a shape rather than a live cross-tenant hole.
    account = WorkspaceAccount.new(domain: "mason.test", subject: "team@evil.test@mason.test")

    refute account.valid?
    assert_includes account.errors[:subject].join, "single email address"
  end
end
