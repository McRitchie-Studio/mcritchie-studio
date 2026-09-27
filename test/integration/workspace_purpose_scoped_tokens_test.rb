require "test_helper"
require "google/apis/gmail_v1"
require "google/apis/drive_v3"

# [integration] The purpose boundary across the WHOLE chain a production caller
# uses: Workspace::GmailClient / DriveClient -> Credentials.authorizer_for ->
# the process-wide authorizer cache -> a real googleauth credential -> the
# `authorization` the real Google service object ends up holding.
#
# WHY THIS TIER EXISTS SEPARATELY FROM THE UNIT TESTS. Those call
# authorizer_for directly, or hand a client a recorder double that records the
# `purpose:` it was passed. Between them they can prove the argument, and the
# scopes of a credential built in isolation — and they still cannot see the
# thing that actually bit, because it is not a property of either call:
#
#   the cache is PROCESS STATE SHARED BY TWO CLIENTS. Keyed on the address
#   alone, whichever client ran first decided what the second one got. Only a
#   test that drives both real clients, for one subject, in one process, in a
#   stated order, can observe that.
#
# Both real orderings are pinned, because both happen: workspace:check reads
# Drive then Gmail as `team@`, and workspace:check_mailbox probes against the
# whole grant and then reads Gmail.
#
# Nothing reaches Google. The key is a synthetic throwaway generated in this
# process, and no access token is ever fetched — the assertions are about what
# each credential is BUILT to ask for.
class WorkspacePurposeScopedTokensTest < ActionDispatch::IntegrationTest
  # One real 2048-bit key per process: googleauth must actually accept it, and
  # generating it per test would dominate the runtime.
  def self.signing_key
    @signing_key ||= OpenSSL::PKey::RSA.new(2048)
  end

  def key_json
    {
      "type" => "service_account",
      "project_id" => "synthetic-project",
      "private_key_id" => "abc123",
      "private_key" => self.class.signing_key.to_pem,
      "client_email" => "synthetic-sa@synthetic-project.iam.gserviceaccount.com",
      "client_id" => "100000000000000000000"
    }.to_json
  end

  setup do
    @original_env = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"]
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    Workspace::Credentials.reset!
    Workspace::Credentials.op_reader = ->(_item) { nil }

    WorkspaceAccount.create!(domain: "wired.test").mark_verified!
  end

  teardown do
    @original_env ? ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = @original_env : ENV.delete("GOOGLE_SERVICE_ACCOUNT_JSON")
    Workspace::Credentials.reset!
    Workspace::Credentials.op_reader = nil
  end

  def gmail_authorization = Workspace::GmailClient.new(subject: "team@wired.test").service.authorization
  def drive_authorization = Workspace::DriveClient.new(subject: "team@wired.test").service.authorization

  test "Drive first, then Gmail: the Gmail service holds a token with no Drive scope" do
    # workspace:check's order. Before the fix the Drive read populated the cache
    # and the Gmail read two lines later was handed that same four-scope object.
    drive = drive_authorization
    gmail = gmail_authorization

    assert_equal Workspace::Credentials::SCOPES, drive.scope
    assert_equal Workspace::Credentials::MAIL_SCOPES, gmail.scope
    refute_includes gmail.scope.join(" "), "auth/drive"
    refute_same drive, gmail
  end

  test "Gmail first, then Drive: the Drive service still holds the whole grant" do
    # The mirror image, and the direction that would break if the fix had been
    # 'always narrow'. Drive genuinely needs drive.readonly + drive.file, so a
    # cache that leaked the MAIL token the other way would be an outage, not a
    # hardening. Order must not decide either answer.
    gmail = gmail_authorization
    drive = drive_authorization

    assert_equal Workspace::Credentials::MAIL_SCOPES, gmail.scope
    assert_equal Workspace::Credentials::SCOPES, drive.scope
    refute_same gmail, drive
  end

  test "both services impersonate the subject, and each client re-reads its own cache entry" do
    # The subject assignment is the silent failure googleauth is famous for
    # here, and it has to survive the new two-part cache key. The second read of
    # each client must also hit the SAME entry — a key that missed every time
    # would pass the scope assertions above while minting a fresh token per
    # call.
    gmail = gmail_authorization
    drive = drive_authorization

    assert_equal "team@wired.test", gmail.sub
    assert_equal "team@wired.test", drive.sub
    assert_same gmail, gmail_authorization, "a second Gmail client reuses the :mail entry"
    assert_same drive, drive_authorization, "a second Drive client reuses the :workspace entry"
  end
end
