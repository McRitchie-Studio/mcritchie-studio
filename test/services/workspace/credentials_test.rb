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
    assert_equal "op://industries-agents/google.industries.agents/credential",
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

  test "an unregistered subject is REFUSED — the allow-list replaces the old pinned constant" do
    # Delegation cannot be narrowed at the grant: it reaches any user in a
    # domain and the CALLER picks whom. That used to be held by a frozen
    # constant; multi-tenant access moved it here. Nothing else changed about
    # the risk, so nothing may weaken this.
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json

    error = assert_raises(Workspace::Credentials::UnregisteredSubject) do
      Workspace::Credentials.authorizer_for("team@not-registered.test")
    end
    assert_includes error.message, "not an ACTIVE workspace_account"
  end

  test "a REGISTERED BUT PENDING workspace is refused too" do
    # Registering is not authorization. A row only becomes impersonatable once
    # a token has actually been issued for it.
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    WorkspaceAccount.create!(domain: "pending.test")

    assert_raises(Workspace::Credentials::UnregisteredSubject) do
      Workspace::Credentials.authorizer_for("team@pending.test")
    end
  end

  test "a revoked workspace stops being impersonatable" do
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    account = WorkspaceAccount.create!(domain: "gone.test")
    account.mark_verified!
    assert Workspace::Credentials.authorizer_for("team@gone.test")

    account.update!(status: "revoked")
    assert_raises(Workspace::Credentials::UnregisteredSubject) do
      Workspace::Credentials.authorizer_for("team@gone.test")
    end
  end

  test "an active workspace's authorizer actually impersonates ITS subject" do
    # THE SILENT FAILURE THIS GUARDS. make_creds drops a `sub:` option, so the
    # assignment is a separate line — and forgetting it does not raise: the
    # credential authenticates as the service account itself, which owns no mail
    # and an empty Drive, so every call would succeed and return nothing.
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    WorkspaceAccount.create!(domain: "live.test").mark_verified!

    authorizer = Workspace::Credentials.authorizer_for("team@live.test")
    assert_equal "team@live.test", authorizer.sub
    assert_equal Workspace::Credentials::SCOPES, authorizer.scope
  end

  test "each workspace gets its OWN credential object — one cannot leak into another" do
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    WorkspaceAccount.create!(domain: "one.test").mark_verified!
    WorkspaceAccount.create!(domain: "two.test").mark_verified!

    one = Workspace::Credentials.authorizer_for("team@one.test")
    two = Workspace::Credentials.authorizer_for("team@two.test")

    assert_equal "team@one.test", one.sub
    assert_equal "team@two.test", two.sub
    refute_same one, two
  end

  test "probe refuses a subject that is not registered at all" do
    # The probe has to work on PENDING rows — that is its job — so the thing
    # stopping it being a domain-sweeping tool is that the row must exist.
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json

    assert_raises(Workspace::Credentials::UnregisteredSubject) do
      Workspace::Credentials.probe("someone@stranger.test")
    end
  end

  test "probe returns a VERDICT, never an authorizer" do
    # It must not become a way to reach data around the allow-list.
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    WorkspaceAccount.create!(domain: "probe.test")

    ok, error = Workspace::Credentials.probe("team@probe.test")
    assert_includes [ true, false ], ok
    assert ok == false || error.nil?
    refute_respond_to ok, :fetch_access_token!
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

  test "probe REFUSES a credential in self-signed-JWT mode, which ignores the subject" do
    # The subject read-back is necessary but not sufficient: in this mode
    # googleauth signs as the service account itself and never sends `sub`,
    # while creds.sub keeps echoing what we set. Every call would then succeed
    # against an empty Drive and a mailbox we do not own.
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    WorkspaceAccount.create!(domain: "selfsigned.test")
    liar = Struct.new(:sub) do
      def fetch_access_token! = true
      def enable_self_signed_jwt? = true
    end.new("team@selfsigned.test")

    ok, error = Workspace::Credentials.stub(:build_authorizer, ->(_s) { liar }) do
      Workspace::Credentials.probe("team@selfsigned.test")
    end

    refute ok, "a credential that cannot carry the subject must not read as proven"
    assert_includes error, "self-signed"
  end

  test "the mode is OFF for our real key shape, and a foreign universe_domain turns it ON" do
    # The tripwire for the test above: it pins that the refusal is inert today
    # AND that its condition is genuinely reachable, so neither half is theatre.
    require "googleauth"
    normal = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(key_json), scope: Workspace::Credentials::SCOPES
    )
    foreign = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(key_json("universe_domain" => "tpc.example.test")),
      scope: Workspace::Credentials::SCOPES
    )

    refute normal.enable_self_signed_jwt?, "delegation would silently stop working"
    assert foreign.enable_self_signed_jwt?, "if this flips, the probe guard is unreachable"
  end
end
