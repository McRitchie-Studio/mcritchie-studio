require "test_helper"

# [unit] Gmail::Client — the read-only surface.
#
# The load-bearing test in this file is "every Gmail-facing call is a GET".
# The lane's whole safety claim is that a leaked credential from here cannot
# send, label, archive or delete, and that claim is only as good as the
# assertion that nothing in this class reaches the Gmail API with a write verb.
class GmailClientTest < ActiveSupport::TestCase
  BLOB = { "client_id" => "cid", "client_secret" => "secret", "refresh_token" => "1//r" }.freeze

  # A stand-in for Gmail::Credentials — hand-rolled, like Slack's, so the suite
  # never shells out to `op`.
  class StubCredentials
    def initialize(blob = BLOB) = @blob = blob
    def configured? = !@blob.nil?
    def credential = @blob
  end

  def response_for(status, body, headers = {})
    klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s]
    response = klass.new("1.1", status.to_s, "")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body.is_a?(String) ? body : body.to_json)
    headers.each { |key, value| response[key] = value }
    response
  end

  # Builds a client whose transport is recorded rather than performed. The
  # recorder keys on HOST, which is what lets the assertions separate the Gmail
  # API from Google's token endpoint.
  def recorded_client(responses, sleeps: [])
    calls = []
    client = Gmail::Client.new(credentials: StubCredentials.new, sleeper: ->(s) { sleeps << s })
    client.define_singleton_method(:perform) do |uri, request|
      calls << { host: uri.host, verb: request.class.name.split("::").last.upcase, path: uri.path }
      responses.shift || raise("no stubbed response left for #{uri}")
    end
    [ client, calls ]
  end

  def token_ok = response_for(200, { "access_token" => "ya29.test", "expires_in" => 3599 })

  test "SCOPES is exactly one frozen readonly scope" do
    assert_equal [ "https://www.googleapis.com/auth/gmail.readonly" ], Gmail::Client::SCOPES
    assert Gmail::Client::SCOPES.frozen?
    refute_includes Gmail::Client::SCOPES.join, "gmail.modify",
      "modify permits send — it must never appear here"
    refute_includes Gmail::Client::SCOPES.join, "gmail.compose",
      "compose covers drafts AND send — there is no draft-only Gmail scope"
    refute_includes Gmail::Client::SCOPES.join, "mail.google.com"
  end

  test "every Gmail-facing call is a GET; the only POST is the token mint" do
    responses = [
      token_ok,
      response_for(200, { "emailAddress" => "alex@mcritchie.studio" }),
      response_for(200, { "messages" => [ { "id" => "m1" } ] }),
      response_for(200, { "raw" => Base64.urlsafe_encode64("From: a@b.c\r\n\r\nhi"), "historyId" => "99" }),
      response_for(200, { "history" => [] })
    ]
    client, calls = recorded_client(responses)

    client.profile
    client.messages_list(query: "from:someone@example.com")
    client.message("m1")
    client.history_list(start_history_id: 5)

    gmail_calls = calls.select { |call| call[:host] == "gmail.googleapis.com" }
    assert_equal 4, gmail_calls.size
    assert_equal [ "GET" ], gmail_calls.map { |call| call[:verb] }.uniq,
      "a write verb against the Gmail API would break the lane's only safety claim"

    token_calls = calls.reject { |call| call[:host] == "gmail.googleapis.com" }
    assert_equal [ { host: "oauth2.googleapis.com", verb: "POST", path: "/token" } ], token_calls
  end

  test "no public method names a mutating Gmail operation" do
    surface = (Gmail::Client.instance_methods(false) + Gmail::Client.methods(false)).map(&:to_s)

    %w[send send_message reply draft drafts create insert modify label archive trash delete
       batch_delete batchDelete update].each do |forbidden|
      refute_includes surface, forbidden, "#{forbidden} must not exist on a read-only client"
    end
  end

  test "messages_list refuses a blank query rather than listing the mailbox" do
    client, calls = recorded_client([])

    [ nil, "", "   " ].each do |blank|
      assert_raises(Gmail::Client::Error) { client.messages_list(query: blank) }
    end
    assert_empty calls, "a blank query must not reach Google at all"
  end

  test "a 401 on a Gmail call is CredentialRevoked, named with its remedy" do
    client, = recorded_client([ token_ok, response_for(401, { "error" => { "status" => "UNAUTHENTICATED" } }) ])

    error = assert_raises(Gmail::Client::CredentialRevoked) { client.profile }
    assert_includes error.message, "password change"
    assert_includes error.message, "bin/gmail-oauth-mint"
  end

  test "invalid_grant at the token endpoint is CredentialRevoked" do
    # This is the shape a password change on the mailbox account produces.
    client, = recorded_client([ response_for(400, { "error" => "invalid_grant" }) ])

    assert_raises(Gmail::Client::CredentialRevoked) { client.profile }
  end

  test "a 404 from history_list is a recoverable expired cursor, not a generic failure" do
    client, = recorded_client([ token_ok, response_for(404, { "error" => { "status" => "NOT_FOUND" } }) ])

    error = assert_raises(Gmail::Client::CursorExpired) { client.history_list(start_history_id: 42) }
    assert_includes error.message, "42"
  end

  test "a 429 retries on Retry-After, then gives up rather than looping" do
    responses = [ token_ok ] + Array.new(8) { response_for(429, {}, "Retry-After" => "3") }
    sleeps = []
    client, = recorded_client(responses, sleeps: sleeps)

    assert_raises(Gmail::Client::Error) { client.profile }
    assert_equal Array.new(Gmail::Client::MAX_RETRIES, 3), sleeps,
      "Retry-After is honoured, and MAX_RETRIES bounds the loop"
  end

  test "a 403 rateLimitExceeded retries but a plain 403 does not" do
    throttled = { "error" => { "errors" => [ { "reason" => "rateLimitExceeded" } ] } }
    client, = recorded_client([ token_ok, response_for(403, throttled),
                                response_for(200, { "emailAddress" => "alex@mcritchie.studio" }) ])
    assert_equal "alex@mcritchie.studio", client.profile["emailAddress"]

    denied = { "error" => { "errors" => [ { "reason" => "insufficientPermissions" } ] } }
    client2, calls2 = recorded_client([ token_ok, response_for(403, denied) ])
    assert_raises(Gmail::Client::ApiError) { client2.profile }
    assert_equal 2, calls2.size, "retrying a permission refusal is just a slower refusal"
  end

  test "paged walks pages and stops on an absent or blank nextPageToken" do
    client, = recorded_client([
      token_ok,
      response_for(200, { "messages" => [ { "id" => "a" } ], "nextPageToken" => "p2" }),
      response_for(200, { "messages" => [ { "id" => "b" } ], "nextPageToken" => "" }),
    ])

    ids = client.paged(:messages_list, "messages", query: "label:deal").map { |m| m["id"] }
    assert_equal %w[a b], ids, "a blank next_cursor means done — treating it as a page loops forever"
  end

  test "decode_raw handles unpadded base64url" do
    raw = "From: a@b.c\r\nSubject: x\r\n\r\nbody"
    unpadded = Base64.urlsafe_encode64(raw).delete("=")

    assert_equal raw, Gmail::Client.decode_raw({ "raw" => unpadded })
  end

  test "a message with no raw payload raises rather than storing nothing" do
    assert_raises(Gmail::Client::Error) { Gmail::Client.decode_raw({ "historyId" => "1" }, id: "m9") }
  end

  test "an unconfigured credential raises before any request" do
    client = Gmail::Client.new(credentials: StubCredentials.new(nil))
    client.define_singleton_method(:perform) { |*| raise "must not reach the network" }

    assert_raises(Gmail::Client::Error) { client.profile }
  end
end
