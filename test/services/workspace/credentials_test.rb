require "test_helper"

# [unit] Workspace::Credentials — source precedence, the absent/malformed split,
# the frozen scope set, and the one thing about domain-wide delegation that
# fails SILENTLY: the subject assignment.
class WorkspaceCredentialsTest < ActiveSupport::TestCase
  # Generated once per process: a real key, because the point of the authorizer
  # test is that googleauth accepts what we hand it. Synthetic and throwaway —
  # it never leaves this process.
  def self.signing_key
    @signing_key ||= OpenSSL::PKey::RSA.new(2048)
  end

  def key_json(overrides = {})
    {
      "type" => "service_account",
      "project_id" => "synthetic-project",
      "private_key_id" => "abc123",
      "private_key" => self.class.signing_key.to_pem,
      "client_email" => "synthetic-sa@synthetic-project.iam.gserviceaccount.com",
      "client_id" => "100000000000000000000"
    }.merge(overrides).to_json
  end

  setup do
    @original_env = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"]
    ENV.delete("GOOGLE_SERVICE_ACCOUNT_JSON")
    Workspace::Credentials.reset!
    Workspace::Credentials.op_reader = ->(_item) { nil }
  end

  teardown do
    @original_env ? ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = @original_env : ENV.delete("GOOGLE_SERVICE_ACCOUNT_JSON")
    Workspace::Credentials.reset!
    Workspace::Credentials.op_reader = nil
  end

  test "ENV wins over 1Password, and op is never consulted" do
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    reads = []
    Workspace::Credentials.op_reader = ->(item) { reads << item; nil }

    assert Workspace::Credentials.configured?
    assert_equal "env", Workspace::Credentials.source
    assert_empty reads, "an env credential must not spend 1Password quota"
  end

  test "falls back to the op read, and caches it" do
    reads = []
    Workspace::Credentials.op_reader = ->(item) { reads << item; key_json }

    assert_equal "1password", Workspace::Credentials.source
    assert_equal "service_account", Workspace::Credentials.credential["type"]
    assert_equal 1, reads.size, "the op read is cached — one call per process"
    assert_equal [ Workspace::Credentials::ITEM ], reads.uniq
  end

  test "the item lives in industries-agents, never an admin vault" do
    # An admin-vault item is unreadable with the agent lane's
    # OP_SERVICE_ACCOUNT_TOKEN, and that read fails silently.
    assert_equal "op://industries-agents/google.drive.agents/credential",
                 Workspace::Credentials::ITEM
    refute_includes Workspace::Credentials::ITEM, "-admin"
  end

  test "absent is a skip, not an error — a desk without op still boots" do
    refute Workspace::Credentials.configured?
    assert_nil Workspace::Credentials.credential
    assert_nil Workspace::Credentials.source
  end

  test "an empty field is absent, not malformed — it is the FILED-EMPTY state" do
    Workspace::Credentials.op_reader = ->(_item) { "" }

    refute Workspace::Credentials.configured?,
      "a placeholder reporting configured? would send the job at Google for an auth error"
  end

  test "unparseable JSON raises rather than reading as an empty Drive" do
    Workspace::Credentials.op_reader = ->(_item) { "-----BEGIN PRIVATE KEY-----" }

    assert Workspace::Credentials.configured?, "the value IS present — that is the point"
    error = assert_raises(Workspace::Credentials::Malformed) { Workspace::Credentials.credential }
    assert_includes error.message, "not valid JSON"
  end

  test "a broken paste never carries key bytes into the exception message" do
    # A PEM with LITERAL newlines is invalid JSON, and JSON::ParserError echoes
    # the input to end of stream — the whole key body, into ErrorLog.
    body = self.class.signing_key.to_pem.lines[1..-2].join.delete("\n")
    Workspace::Credentials.op_reader = ->(_item) { key_json.gsub("\\n", "\n") }

    error = assert_raises(Workspace::Credentials::Malformed) { Workspace::Credentials.credential }
    assert_includes error.message, "not valid JSON"
    refute_includes error.message, body[0, 40], "private key bytes rode out in the exception"
  end

  test "missing key fields name themselves" do
    Workspace::Credentials.op_reader = ->(_item) { { "type" => "service_account" }.to_json }

    error = assert_raises(Workspace::Credentials::Malformed) { Workspace::Credentials.credential }
    assert_includes error.message, "client_email"
    assert_includes error.message, "private_key"
  end

  test "an OAuth client secret is refused by TYPE, with the wrong-file said out loud" do
    # The likeliest misfiling: the Cloud console also hands out a client_secret
    # JSON, which parses fine and carries neither of the fields we need.
    oauth_secret = { "web" => { "client_id" => "x", "client_secret" => "y" } }.to_json
    Workspace::Credentials.op_reader = ->(_item) { oauth_secret }

    error = assert_raises(Workspace::Credentials::Malformed) { Workspace::Credentials.credential }
    assert_includes error.message, "client_email"
  end

  test "a service-account-shaped key with the wrong type is named precisely" do
    Workspace::Credentials.op_reader = ->(_item) { key_json("type" => "authorized_user") }

    error = assert_raises(Workspace::Credentials::Malformed) { Workspace::Credentials.credential }
    assert_includes error.message, "authorized_user"
    assert_includes error.message, "wrong JSON file"
  end

  test "SCOPES is exactly the four minimum grants, frozen" do
    assert_equal [
      "https://www.googleapis.com/auth/drive.readonly",
      "https://www.googleapis.com/auth/drive.file",
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.compose"
    ], Workspace::Credentials::SCOPES
    assert Workspace::Credentials::SCOPES.frozen?
  end

  test "SCOPES holds no full-drive and no send grant" do
    joined = Workspace::Credentials::SCOPES.join(" ")

    refute_includes joined, "auth/drive ", "full drive would make the never-edit guardrail unenforceable"
    refute_equal true, Workspace::Credentials::SCOPES.include?("https://www.googleapis.com/auth/drive")
    refute_includes joined, "gmail.send"
    refute_includes joined, "gmail.modify"
    refute_includes joined, "mail.google.com"
  end

  test "the subject is pinned to a constant, not taken from a caller" do
    assert_equal "team@mcritchie.industries", Workspace::Credentials::SUBJECT
    # No writer: a caller cannot repoint the impersonation.
    refute Workspace::Credentials.respond_to?(:subject=)
  end

  test "the authorizer actually impersonates the subject" do
    # THE SILENT FAILURE THIS GUARDS. make_creds refuses a `sub:` option, so the
    # assignment is a separate line — and forgetting it does not raise: the
    # credential authenticates as the service account itself, which owns no mail
    # and an empty Drive, so every call would succeed and return nothing.
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json

    assert_equal "team@mcritchie.industries", Workspace::Credentials.subject
    assert_equal Workspace::Credentials::SCOPES, Workspace::Credentials.authorizer.scope
  end

  test "make_creds SILENTLY DROPS a sub option — why the assignment is a separate line" do
    # Pins the upstream behaviour credentials.rb documents, and it is the nastier
    # of the two shapes: passing `sub:` here looks right, warns only on stderr,
    # and yields a credential that impersonates NOBODY. If a future googleauth
    # starts honouring it, this test fails and tells us the comment is stale
    # rather than leaving it to be believed forever.
    require "googleauth"
    creds = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(key_json), scope: Workspace::Credentials::SCOPES,
      sub: "someone@example.test"
    )

    assert_nil creds.sub, "if this ever passes sub through, the separate assignment can go"
  end

  test "the op read is bounded" do
    assert_operator Workspace::Credentials::OP_TIMEOUT_SECONDS, :<=, 30,
      "op blocks for biometric unlock on a cold session; an unbounded read hangs a cron dyno"
  end
end
