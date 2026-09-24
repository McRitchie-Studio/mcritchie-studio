require "test_helper"

# [unit] WorkspaceMailbox — the named addresses we may draft as, and the rule
# that BOTH the mailbox and its workspace must be active before anything may
# impersonate it.
class WorkspaceMailboxTest < ActiveSupport::TestCase
  def workspace(domain = "mason.test", active: true)
    WorkspaceAccount.create!(domain: domain).tap { |a| a.mark_verified! if active }
  end

  test "several mailboxes may live in one workspace, one row per address" do
    account = workspace
    account.workspace_mailboxes.create!(address: "alex@mason.test")
    account.workspace_mailboxes.create!(address: "team@mason.test")

    assert_equal 2, account.workspace_mailboxes.count
    refute account.workspace_mailboxes.new(address: " ALEX@Mason.test ").valid?,
      "normalized duplicates are the same mailbox"
  end

  test "a mailbox must be an address in its OWN workspace's domain" do
    account = workspace
    [ "alex@other.test", "@mason.test", "a@b.test@mason.test" ].each do |address|
      refute account.workspace_mailboxes.new(address: address).valid?, "#{address} must be refused"
    end
  end

  test "impersonatable only when the mailbox AND its workspace are active" do
    account = workspace
    mailbox = account.workspace_mailboxes.create!(address: "alex@mason.test")
    refute WorkspaceMailbox.impersonatable?("alex@mason.test"), "pending mailbox"

    mailbox.mark_verified!
    assert WorkspaceMailbox.impersonatable?(" Alex@Mason.test ")
    assert WorkspaceAccount.impersonatable?("alex@mason.test"), "Credentials' one question sees it too"

    account.revoke!("paused")
    refute WorkspaceMailbox.impersonatable?("alex@mason.test"),
      "revoking the workspace shuts every mailbox in it — no second switch to forget"
  end

  test "an active mailbox in a PENDING workspace is still refused" do
    account = workspace(active: false)
    mailbox = account.workspace_mailboxes.create!(address: "alex@mason.test")
    mailbox.update_columns(status: "active")

    refute WorkspaceMailbox.impersonatable?("alex@mason.test")
  end

  test "a revoked mailbox is never resurrected by a check" do
    mailbox = workspace.workspace_mailboxes.create!(address: "alex@mason.test")
    mailbox.mark_verified!
    mailbox.revoke!("left the company")

    assert_raises(WorkspaceAccount::Revoked) { mailbox.mark_verified! }
    mailbox.mark_unverified!("unauthorized_client")
    assert_equal "revoked", mailbox.reload.status
    assert_match(/revoked: left the company/, mailbox.notes)
  end

  test "registered_address? knows workspace subjects and mailboxes, nothing else" do
    workspace.workspace_mailboxes.create!(address: "alex@mason.test")

    assert WorkspaceAccount.registered_address?("team@mason.test")
    assert WorkspaceAccount.registered_address?("ALEX@mason.test")
    refute WorkspaceAccount.registered_address?("ceo@mason.test"),
      "an unlisted address in a registered domain is NOT registered — probe must not sweep a domain"
  end
end
