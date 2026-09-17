require "test_helper"

# [unit] Gmail::MailboxIngest — the query rule, the cursor, and the two
# properties that make a read of a private mailbox defensible:
#
#   * a message the query does not match is NEVER FETCHED (so its body never
#     enters this process, let alone the bucket), and
#   * a missing query REFUSES rather than defaulting to the whole mailbox.
#
# Both are asserted by watching what the client double was ASKED for, which is
# the only way to prove a non-event.
class GmailMailboxIngestTest < ActiveSupport::TestCase
  # Records every call, so an assertion can be about what was NOT requested.
  # Hand-rolled like Slack's doubles rather than a mocking library.
  class ClientDouble
    attr_reader :fetched, :listed, :histories

    def initialize(matching: {}, history: [], history_raises: nil)
      @matching = matching          # id => raw MIME
      @history = history            # history records as Gmail returns them
      @history_raises = history_raises
      @fetched = []
      @listed = []
      @histories = []
    end

    def paged(method, key, **params)
      case method
      when :messages_list
        @listed << params[:query]
        { "messages" => @matching.keys.map { |id| { "id" => id } } }[key] || []
      when :history_list
        @histories << params[:start_history_id]
        raise Gmail::Client::CursorExpired, "expired" if @history_raises

        { "history" => @history }[key] || []
      else
        raise "unexpected paged call: #{method}"
      end
    end

    def message(id)
      @fetched << id
      raw = @matching[id] or raise Gmail::Client::Error, "double has no message #{id}"
      { "id" => id, "historyId" => (1000 + @matching.keys.index(id)).to_s,
        "raw" => Base64.urlsafe_encode64(raw) }
    end
  end

  # Captures the bucket writes and delegates the row creation to the REAL
  # DeskCapture.ingest_raw, so the trust seam is exercised rather than stubbed.
  class StorageDouble
    attr_reader :stored

    def initialize = @stored = []

    def store(key, body, content_type: nil)
      @stored << { key: key, content_type: content_type, bytes: body.to_s.bytesize }
      key
    end

    def ingest_raw(**kwargs) = DeskCapture.ingest_raw(**kwargs)
  end

  class CredentialsDouble
    def initialize(configured: true) = @configured = configured
    def configured? = @configured
  end

  def mime(from:, subject: "Revised figure", body: "the number moved to 412")
    <<~MIME
      From: #{from}
      To: alex@mcritchie.studio
      Subject: #{subject}
      Message-ID: <#{SecureRandom.hex(6)}@example.test>
      Date: Tue, 16 Sep 2026 10:00:00 -0600
      Content-Type: text/plain

      #{body}
    MIME
  end

  setup do
    @original_query = ENV["GMAIL_CAPTURE_QUERY"]
    ENV["GMAIL_CAPTURE_QUERY"] = "from:counterparty@example.test"
  end

  teardown do
    @original_query ? ENV["GMAIL_CAPTURE_QUERY"] = @original_query : ENV.delete("GMAIL_CAPTURE_QUERY")
  end

  def ingest(client:, storage: StorageDouble.new, credentials: CredentialsDouble.new)
    [ Gmail::MailboxIngest.new(client: client, storage: storage, credentials: credentials).call, storage ]
  end

  test "a blank query refuses and asks Google for nothing at all" do
    ENV["GMAIL_CAPTURE_QUERY"] = "   "
    client = ClientDouble.new(matching: { "m1" => mime(from: "a@example.test") })

    result, storage = ingest(client: client)

    assert result.ok?, "refusing is not a failure — it is the safe default"
    assert_includes result.mode, "refusing to read the whole mailbox"
    assert_equal 0, result.matched
    assert_empty client.listed, "no list call may be made without a query"
    assert_empty client.fetched
    assert_empty storage.stored
  end

  test "an unconfigured credential skips politely without touching op" do
    result, = ingest(client: nil, credentials: CredentialsDouble.new(configured: false))

    assert result.ok?
    assert_includes result.mode, "no Gmail credential"
  end

  test "the first run does a bounded backfill, and the bound rides in the query" do
    client = ClientDouble.new(matching: { "m1" => mime(from: "counterparty@example.test") })

    result, storage = ingest(client: client)

    assert_equal 1, result.matched
    assert_equal 1, result.ingested
    assert_includes result.mode, "no cursor yet"
    assert_equal 1, client.listed.size
    assert_match(/\Afrom:counterparty@example\.test after:\d{4}\/\d{2}\/\d{2}\z/, client.listed.first,
      "the operator's query plus a server-side date bound — never an unbounded mailbox walk")
    assert_equal [ "gmail/m1.eml" ], storage.stored.map { |write| write[:key] }
    assert_equal [ "message/rfc822" ], storage.stored.map { |write| write[:content_type] }
  end

  test "a history id the query does not match is never fetched" do
    # Gmail's history reports EVERY change in the mailbox, including personal
    # mail that has nothing to do with the deal. This is the privacy property:
    # those ids are intersected with a query-scoped list, so they are never
    # downloaded.
    DeskCaptureItem.create!(s3_key: "gmail/seed.eml", source: "gmail", history_id: 500,
                            status: "received")
    history = [ { "messagesAdded" => [ { "message" => { "id" => "deal1" } },
                                       { "message" => { "id" => "private-doctor-note" } } ] } ]
    client = ClientDouble.new(matching: { "deal1" => mime(from: "counterparty@example.test") },
                              history: history)

    result, storage = ingest(client: client)

    assert_equal [ 500 ], client.histories, "resumes AT the recorded cursor"
    assert_equal [ "deal1" ], client.fetched,
      "a changed message outside the query must never be requested"
    refute_includes client.fetched, "private-doctor-note"
    assert_equal [ "gmail/deal1.eml" ], storage.stored.map { |write| write[:key] }
    assert_equal 1, result.ingested
    assert_includes result.mode, "incremental from 500"
  end

  test "an expired cursor falls back to a bounded full sync instead of leaving a gap" do
    DeskCaptureItem.create!(s3_key: "gmail/seed.eml", source: "gmail", history_id: 7,
                            status: "received")
    client = ClientDouble.new(matching: { "m1" => mime(from: "counterparty@example.test") },
                              history_raises: true)

    result, = ingest(client: client)

    assert result.ok?, "an aged-out cursor is an expected path, not a failure"
    assert_includes result.mode, "expired"
    assert_equal 1, result.ingested
    assert_equal 1, client.listed.size
  end

  test "the cursor is the max history id DURABLY RECORDED, so a lost row cannot be stepped over" do
    client = ClientDouble.new(matching: {
      "m1" => mime(from: "counterparty@example.test"),
      "m2" => mime(from: "counterparty@example.test")
    })

    ingest(client: client)

    assert_equal 1001, DeskCaptureItem.gmail_cursor
    assert_equal [ 1000, 1001 ], DeskCaptureItem.from_gmail.order(:history_id).pluck(:history_id)
  end

  test "a message already held is neither re-fetched nor re-stored" do
    raw = mime(from: "counterparty@example.test")
    first, first_storage = ingest(client: ClientDouble.new(matching: { "m1" => raw }))
    assert first.ok?, "first pull failed: #{first.error}"
    assert_equal 1, first_storage.stored.size

    # The cursor overlap re-offers the message we just recorded (so does a full
    # sync after an expired cursor). The s3_key check is what makes that free.
    second_client = ClientDouble.new(
      matching: { "m1" => raw },
      history: [ { "messagesAdded" => [ { "message" => { "id" => "m1" } } ] } ]
    )
    result, second_storage = ingest(client: second_client)

    assert_equal 1, result.matched, "the id IS offered again — that is the case under test"
    assert_equal 0, result.ingested
    assert_equal 1, result.skipped
    assert_empty second_client.fetched, "idempotence means not paying for the bytes twice"
    assert_empty second_storage.stored
    assert_equal 1, DeskCaptureItem.from_gmail.count
  end

  test "a quiet mailbox reports nothing new without touching the bucket" do
    ingest(client: ClientDouble.new(matching: { "m1" => mime(from: "counterparty@example.test") }))

    # No new history since the cursor: the incremental path short-circuits
    # before it even lists, so a quiet day costs one call.
    quiet = ClientDouble.new(matching: { "m1" => "unused" })
    result, storage = ingest(client: quiet)

    assert result.ok?
    assert_equal 0, result.matched
    assert_empty quiet.listed, "no changes means no list call is needed at all"
    assert_empty quiet.fetched
    assert_empty storage.stored
  end

  test "a revoked credential is reported loudly, never as a quiet empty pull" do
    client = Object.new
    client.define_singleton_method(:paged) { |*, **| raise Gmail::Client::CredentialRevoked }

    result, = ingest(client: client)

    refute result.ok?, "this is the failure that would otherwise hide for weeks"
    assert_includes result.error, "password change"
    assert_equal "failed", result.mode
  end

  test "a malformed credential is reported loudly too" do
    client = Object.new
    client.define_singleton_method(:paged) { |*, **| raise Gmail::Credentials::Malformed, "bad item" }

    result, = ingest(client: client)

    refute result.ok?
    assert_includes result.error, "bad item"
  end

  test "the ingest calls nothing but the two read verbs" do
    # A strict double: anything beyond the reads it implements is recorded and
    # raised, so an ingest that ever reached for send/modify/trash would fail
    # here by name rather than pass quietly.
    attempted = []
    strict = Class.new(ClientDouble) do
      define_method(:method_missing) do |name, *args, **kwargs|
        attempted << name
        raise NoMethodError, "ingest reached for ##{name}"
      end
      define_method(:respond_to_missing?) { |*| false }
    end.new(matching: { "m1" => mime(from: "counterparty@example.test") })

    result, = ingest(client: strict)

    assert result.ok?, result.error
    assert_equal 1, result.ingested
    assert_empty attempted,
      "the ingest must need only #paged and #message — both reads"
  end
end
