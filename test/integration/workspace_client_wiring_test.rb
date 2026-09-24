require "test_helper"
require "faraday"

# [integration] The clients across their real I/O boundary: our wrapper -> the
# actual google-apis service object -> a stubbed HTTP transport -> a parsed
# response object.
#
# WHY THIS TIER EXISTS SEPARATELY FROM THE UNIT TESTS. Those inject a service
# double whose methods take `**kwargs`, so every parameter name they are handed
# is accepted — a `page_size:` typed as `pageSize:`, or a field list the API
# would reject, passes a green unit suite and fails in production. Here the real
# gem builds the request, so the query string it actually puts on the wire is
# observable, and a wrong parameter name cannot survive.
#
# Nothing reaches Google: the transport is a Faraday test adapter and the
# authorization is a literal bearer string, so googleauth is never involved and
# no credential is read.
class WorkspaceClientWiringTest < ActionDispatch::IntegrationTest
  # Records the requests the gem actually issued, and replies from a script.
  class Transport
    attr_reader :requests

    def initialize
      @requests = []
      @replies = {}
    end

    def reply(path_fragment, body, status: 200)
      @replies[path_fragment] = [ status, body ]
      self
    end

    def connection
      recorder = self
      Faraday.new do |builder|
        builder.adapter :test do |stub|
          stub.get(/.*/) { |env| recorder.handle(env) }
          stub.post(/.*/) { |env| recorder.handle(env) }
          stub.put(/.*/) { |env| recorder.handle(env) }
          stub.patch(/.*/) { |env| recorder.handle(env) }
        end
      end
    end

    def handle(env)
      @requests << { method: env.method, path: env.url.path, query: env.url.query,
                     body: env.body }
      _fragment, (status, body) = @replies.find { |fragment, _| env.url.path.include?(fragment) }
      [ status || 404, { "Content-Type" => "application/json" }, (body || {}).to_json ]
    end

    def query_for(path_fragment)
      request = @requests.find { |r| r[:path].include?(path_fragment) }
      return nil if request.nil?

      Rack::Utils.parse_nested_query(request[:query].to_s)
    end
  end

  def drive(transport)
    service = Google::Apis::DriveV3::DriveService.new
    service.authorization = "ya29.test-bearer"
    service.client = transport.connection
    Workspace::DriveClient.new(service: service, sleeper: ->(_s) { })
  end

  def gmail(transport)
    service = Google::Apis::GmailV1::GmailService.new
    service.authorization = "ya29.test-bearer"
    service.client = transport.connection
    Workspace::GmailClient.new(service: service, sleeper: ->(_s) { })
  end

  test "files_list puts the query, page size and owner field on the wire" do
    transport = Transport.new.reply("/drive/v3/files", {
      "files" => [ { "id" => "f1", "name" => "Doc", "mimeType" => "application/pdf",
                     "owners" => [ { "emailAddress" => "third.party@example.test" } ] } ]
    })

    page = drive(transport).files_list(query: "'abc' in parents", cursor: "tok", limit: 7)

    query = transport.query_for("/drive/v3/files")
    assert_equal "'abc' in parents", query["q"]
    assert_equal "tok", query["pageToken"], "our page_size/page_token names must map to Google's camelCase"
    assert_equal "7", query["pageSize"]
    assert_equal "true", query["supportsAllDrives"]
    assert_includes query["fields"], "owners(emailAddress)"

    # And the response parsed into real gem objects, not a hash.
    assert_equal "f1", page.files.first.id
    assert_equal "third.party@example.test", page.files.first.owners.first.email_address
  end

  test "paged walks two real responses and stops" do
    transport = Transport.new
    calls = 0
    transport.define_singleton_method(:handle) do |env|
      @requests << { method: env.method, path: env.url.path, query: env.url.query, body: env.body }
      calls += 1
      body = calls == 1 ? { "files" => [ { "id" => "a" } ], "nextPageToken" => "p2" }
                        : { "files" => [ { "id" => "b" } ] }
      [ 200, { "Content-Type" => "application/json" }, body.to_json ]
    end

    files = drive(transport).paged(query: "trashed = false")

    assert_equal %w[a b], files.map(&:id)
    assert_equal 2, transport.requests.size
  end

  test "messages_list sends Gmail's q and maxResults, and nothing else" do
    transport = Transport.new.reply("/gmail/v1/users/me/messages",
                                    { "messages" => [ { "id" => "m1", "threadId" => "t1" } ] })

    result = gmail(transport).messages_list(query: "from:someone@example.test", limit: 13)

    query = transport.query_for("/gmail/v1/users/me/messages")
    assert_equal "from:someone@example.test", query["q"]
    assert_equal "13", query["maxResults"]
    assert_equal "m1", result.messages.first.id
    assert_equal "t1", result.messages.first.thread_id
  end

  test "a draft POST carries the raw message and never hits a send path" do
    transport = Transport.new.reply("/gmail/v1/users/me/drafts",
                                    { "id" => "d7", "message" => { "id" => "m7" } })
    mime = "From: a@example.test\r\nSubject: s\r\n\r\nbody"

    draft = gmail(transport).drafts_create(raw: mime)

    request = transport.requests.find { |r| r[:path].include?("/drafts") }
    assert_equal :post, request[:method]
    assert_equal "/gmail/v1/users/me/drafts", request[:path],
      "the drafts collection, NOT /drafts/send"
    # SINGLY encoded. This assertion is the one that caught the real bug: the
    # client pre-encoded the MIME and the gem encoded it again, putting
    # base64(base64(mime)) on the wire — a draft Gmail would have rendered as
    # gibberish, invisible to every unit test.
    encoded = request[:body].to_s[/"raw":"([^"]+)"/, 1]
    assert_equal mime, Base64.urlsafe_decode64(encoded),
      "the wire must carry the MIME encoded exactly once"
    assert_equal "d7", draft.id

    # The whole point, asserted against the traffic rather than the source: no
    # request this client makes can be a send.
    transport.requests.each do |r|
      refute_match %r{/send\z}, r[:path], "a send path reached the wire: #{r[:path]}"
    end
  end

  test "a threaded reply draft crosses the real gem: bold link, threadId, no send path" do
    account = WorkspaceAccount.create!(domain: "mason.test")
    account.mark_verified!
    account.workspace_mailboxes.create!(address: "alex@mason.test").mark_verified!

    headers = [ [ "From", "Billing <billing@vendor.test>" ], [ "Subject", "Payment failed" ],
                [ "Message-ID", "<m2@vendor.test>" ] ].map { |n, v| { "name" => n, "value" => v } }
    transport = Transport.new
      .reply("/gmail/v1/users/me/messages", { "messages" => [ { "id" => "m2", "threadId" => "t-7" } ] })
      .reply("/gmail/v1/users/me/threads/t-7",
             { "id" => "t-7", "messages" => [ { "id" => "m2", "threadId" => "t-7", "payload" => { "headers" => headers } } ] })
      .reply("/gmail/v1/users/me/drafts", { "id" => "r-5", "message" => { "id" => "msg-5", "threadId" => "t-7" } })

    result = Workspace::Drafter.new(mailbox: "alex@mason.test", drafted_by: "alex", client: gmail(transport))
                               .call(markdown: "Retrying with **[Claude](https://claude.ai)** now.",
                                     reply_query: "from:vendor.test subject:payment")

    thread_query = transport.query_for("/threads/t-7")
    assert_equal "metadata", thread_query["format"], "a reply reads headers only, not bodies"

    post = transport.requests.find { |r| r[:method] == :post }
    assert_equal "/gmail/v1/users/me/drafts", post[:path]
    wire = JSON.parse(post[:body].to_s)
    assert_equal "t-7", wire.dig("message", "threadId"), "the draft must land INSIDE the named thread"
    mail = Mail.new(Base64.urlsafe_decode64(wire.dig("message", "raw")))
    assert_equal "Re: Payment failed", mail.subject
    assert_includes mail.html_part.decoded, '<strong><a href="https://claude.ai">Claude</a></strong>'

    assert_equal "msg-5", result.log.gmail_message_id
    transport.requests.each { |r| refute_match %r{/send\z}, r[:path] }
    assert_equal [ :get, :post ], transport.requests.map { |r| r[:method] }.uniq.sort
  end

  test "files_export asks for the export endpoint with the target type" do
    transport = Transport.new.reply("/drive/v3/files/doc1/export", "PDF-BYTES")

    drive(transport).files_export("doc1", mime_type: "application/pdf")

    query = transport.query_for("/export")
    assert_equal "application/pdf", query["mimeType"]
  end

  test "a 429 over the real transport is retried, then surfaces as our one error type" do
    transport = Transport.new
    transport.define_singleton_method(:handle) do |env|
      @requests << { method: env.method, path: env.url.path, query: env.url.query, body: env.body }
      [ 429, { "Content-Type" => "application/json", "Retry-After" => "1" },
        { "error" => { "code" => 429, "message" => "rateLimitExceeded" } }.to_json ]
    end

    assert_raises(Workspace::ApiRetry::Error) { drive(transport).files_list(query: "x") }
    assert_operator transport.requests.size, :>, 1, "it must actually have retried"
  end
end
