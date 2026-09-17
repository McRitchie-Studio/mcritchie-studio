require "test_helper"

# [unit] Gmail::Credentials — source precedence, and the distinction the whole
# lane's diagnosability rests on: ABSENT is a skip, MALFORMED is an error.
class GmailCredentialsTest < ActiveSupport::TestCase
  BLOB = { "client_id" => "cid.apps.googleusercontent.com",
           "client_secret" => "secret", "refresh_token" => "1//refresh" }.freeze

  setup do
    @original_env = ENV["GMAIL_OAUTH_CREDENTIAL"]
    ENV.delete("GMAIL_OAUTH_CREDENTIAL")
    Gmail::Credentials.reset!
    Gmail::Credentials.op_reader = ->(_item) { nil }
  end

  teardown do
    @original_env ? ENV["GMAIL_OAUTH_CREDENTIAL"] = @original_env : ENV.delete("GMAIL_OAUTH_CREDENTIAL")
    Gmail::Credentials.reset!
    Gmail::Credentials.op_reader = nil
  end

  test "ENV wins over 1Password, and op is never consulted" do
    ENV["GMAIL_OAUTH_CREDENTIAL"] = BLOB.to_json
    reads = []
    Gmail::Credentials.op_reader = ->(item) { reads << item; nil }

    assert Gmail::Credentials.configured?
    assert_equal "env", Gmail::Credentials.source
    assert_equal BLOB, Gmail::Credentials.credential
    assert_empty reads, "an env credential must not spend 1Password quota"
  end

  test "falls back to the op read, and caches it" do
    reads = []
    Gmail::Credentials.op_reader = ->(item) { reads << item; BLOB.to_json }

    assert_equal "1password", Gmail::Credentials.source
    assert_equal "1//refresh", Gmail::Credentials.refresh_token
    assert_equal "cid.apps.googleusercontent.com", Gmail::Credentials.client_id
    assert_equal "secret", Gmail::Credentials.client_secret
    assert_equal 1, reads.size, "the op read is cached — one call per process, not one per field"
    assert_equal [ Gmail::Credentials::ITEM ], reads.uniq
  end

  test "the item path is studio-agents, never the admin vault" do
    # studio-agents-admin is unreadable with the agent lane's
    # OP_SERVICE_ACCOUNT_TOKEN, and that read fails SILENTLY.
    assert_equal "op://studio-agents/gmail.studio.agents/credential", Gmail::Credentials::ITEM
    refute_includes Gmail::Credentials::ITEM, "studio-agents-admin"
  end

  test "absent is a skip, not an error — a desk without op still boots" do
    refute Gmail::Credentials.configured?
    assert_nil Gmail::Credentials.credential
    assert_nil Gmail::Credentials.source
  end

  test "an empty field is absent, not malformed — it is the FILED-EMPTY state" do
    Gmail::Credentials.op_reader = ->(_item) { "" }

    refute Gmail::Credentials.configured?,
      "a placeholder that reported configured? would send the job at Google for an invalid_grant"
  end

  test "unparseable JSON raises rather than reading as an empty mailbox" do
    Gmail::Credentials.op_reader = ->(_item) { "{client_id: oops" }

    assert Gmail::Credentials.configured?, "the value IS present — that is the point"
    error = assert_raises(Gmail::Credentials::Malformed) { Gmail::Credentials.credential }
    assert_includes error.message, "not valid JSON"
  end

  test "a bare refresh token in the field is caught by SHAPE, not by the parse" do
    # "1//abc" parses — as the number 1 followed by a comment — so only the
    # Hash check catches it. This is the likeliest way the item gets misfiled.
    Gmail::Credentials.op_reader = ->(_item) { "1//0gBVx-bare-refresh-token" }

    error = assert_raises(Gmail::Credentials::Malformed) { Gmail::Credentials.credential }
    assert_includes error.message, "must hold a JSON object"
    Gmail::Credentials::REQUIRED_KEYS.each { |key| assert_includes error.message, key }
  end

  test "a missing key names itself" do
    Gmail::Credentials.op_reader = ->(_item) { { "client_id" => "cid" }.to_json }

    error = assert_raises(Gmail::Credentials::Malformed) { Gmail::Credentials.credential }
    assert_includes error.message, "client_secret"
    assert_includes error.message, "refresh_token"
  end

  test "a blank value inside the object counts as missing" do
    Gmail::Credentials.op_reader = ->(_item) { BLOB.merge("refresh_token" => "  ").to_json }

    assert_raises(Gmail::Credentials::Malformed) { Gmail::Credentials.credential }
  end

  test "a JSON array is not a credential" do
    Gmail::Credentials.op_reader = ->(_item) { [ BLOB ].to_json }

    assert_raises(Gmail::Credentials::Malformed) { Gmail::Credentials.credential }
  end

  test "extra keys in the item are ignored, not passed along" do
    Gmail::Credentials.op_reader = ->(_item) { BLOB.merge("notes" => "filed by steffon").to_json }

    assert_equal Gmail::Credentials::REQUIRED_KEYS.sort, Gmail::Credentials.credential.keys.sort
  end

  test "the op read is bounded" do
    assert_operator Gmail::Credentials::OP_TIMEOUT_SECONDS, :<=, 30,
      "op blocks for biometric unlock on a cold session; an unbounded read hangs a cron dyno"
  end
end
