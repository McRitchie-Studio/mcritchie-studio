require "test_helper"

# [integration] The Gmail mouth end to end: Gmail API (stubbed) -> raw .eml in
# the desk bucket (stubbed) -> a real DeskCaptureItem on the real sweep queue,
# through the REAL DeskCapture.ingest_raw and DeskCapture::Parser.
#
# What this file exists to prove is the TRUST SEAM. The team@ door quarantines
# a stranger, and it must keep doing so; the Gmail door must NOT, because a
# counterparty's address in From: is the expected truth on a message already
# delivered to Mr. McRitchie's own mailbox. Getting that backwards in either
# direction is the bug — one drops the entire payload, the other opens a public
# address into the deal room.
class GmailCaptureIngestTest < ActionDispatch::IntegrationTest
  COUNTERPARTY = "broker@counterparty.example".freeze

  class ClientDouble
    attr_reader :fetched

    def initialize(messages) = (@messages = messages; @fetched = [])

    def paged(method, key, **)
      case [ method, key ]
      when [ :messages_list, "messages" ]
        @messages.keys.map { |id| { "id" => id } }
      when [ :history_list, "history" ]
        # The cursor overlap re-offers what we already hold; the s3_key check
        # is what makes a second pull free.
        [ { "messagesAdded" => @messages.keys.map { |id| { "message" => { "id" => id } } } } ]
      else
        []
      end
    end

    def message(id)
      @fetched << id
      { "id" => id, "historyId" => "4242", "raw" => Base64.urlsafe_encode64(@messages[id]) }
    end
  end

  class StorageDouble
    attr_reader :stored

    def initialize = @stored = {}

    def store(key, body, content_type: nil)
      @stored[key] = { body: body, content_type: content_type }
      key
    end

    def ingest_raw(**kwargs) = DeskCapture.ingest_raw(**kwargs)
  end

  class CredentialsDouble
    def configured? = true
  end

  def deal_mime
    <<~MIME
      From: Deal Broker <#{COUNTERPARTY}>
      To: alex@mcritchie.studio
      Subject: [welding] Revised asking price
      Message-ID: <deal-1@counterparty.example>
      Date: Tue, 16 Sep 2026 09:30:00 -0600
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="b1"

      --b1
      Content-Type: text/plain

      The asking price moved to 412 after the equipment appraisal.
      --b1
      Content-Type: text/plain
      Content-Disposition: attachment; filename="Appraisal (Sep 16).txt"

      Press brake appraised at 41,000.
      --b1--
    MIME
  end

  setup do
    @original_query = ENV["GMAIL_CAPTURE_QUERY"]
    ENV["GMAIL_CAPTURE_QUERY"] = "from:#{COUNTERPARTY}"
    @storage = StorageDouble.new
  end

  teardown do
    @original_query ? ENV["GMAIL_CAPTURE_QUERY"] = @original_query : ENV.delete("GMAIL_CAPTURE_QUERY")
  end

  def pull(messages)
    Gmail::MailboxIngest.new(client: ClientDouble.new(messages), storage: @storage,
                             credentials: CredentialsDouble.new).call
  end

  test "a counterparty's mail lands swept-ready, body and attachment extracted" do
    result = pull("gm1" => deal_mime)

    assert result.ok?, result.error
    assert_equal 1, result.ingested
    assert_equal 0, result.quarantined

    item = DeskCaptureItem.find_by!(s3_key: "gmail/gm1.eml")
    assert_equal "gmail", item.source
    assert_equal "received", item.status,
      "quarantining this would drop the body and leave the attachment unextracted"
    assert_equal COUNTERPARTY, item.from_addr
    assert_equal 4242, item.history_id
    assert_equal "commercial-welding-llc", item.entity_hint
    assert_includes item.body_text, "asking price moved to 412"
    assert_equal 1, item.attachment_count
    assert_equal "Appraisal (Sep 16).txt", item.attachments.first["filename"]

    assert_includes DeskCaptureItem.awaiting_sweep, item, "it must reach the sweep queue"
  end

  test "the raw .eml is stored durably, and the attachment lands under parsed/" do
    pull("gm1" => deal_mime)

    assert_equal "message/rfc822", @storage.stored["gmail/gm1.eml"][:content_type]
    assert_includes @storage.stored["gmail/gm1.eml"][:body], "Revised asking price"
  end

  test "the public team@ door still quarantines the same stranger" do
    # The Gmail leg does NOT widen DESK_ALLOWED_SENDERS. Proven by running the
    # identical message through the Resend transport, which passes no source.
    DeskCapture.ingest_raw(raw: deal_mime, s3_key: "resend/re_x.eml")

    item = DeskCaptureItem.find_by!(s3_key: "resend/re_x.eml")
    assert_equal "resend", item.source
    assert_equal "quarantined", item.status,
      "team@ is public — an unknown From: there is an injection vector, not a deal email"
    assert_nil item.body_text
    assert_equal 0, item.attachment_count
  end

  test "a trusted source cannot be forged from inside the message" do
    # The only thing that grants trust is the `source` ARGUMENT our own code
    # passes. Headers a stranger controls must not reach it.
    forged = deal_mime.sub("MIME-Version: 1.0",
                           "X-Forwarded-For: alex@mcritchie.studio\nX-Source: gmail\nMIME-Version: 1.0")
    DeskCapture.ingest_raw(raw: forged, s3_key: "resend/re_forged.eml")

    assert_equal "quarantined", DeskCaptureItem.find_by!(s3_key: "resend/re_forged.eml").status
    assert_equal %w[gmail], DeskCapture::TRUSTED_SOURCES,
      "widening this list is the only way the public door could lose its allowlist"
  end

  test "Mr McRitchie's own forward through team@ is unaffected" do
    own = deal_mime.sub("From: Deal Broker <#{COUNTERPARTY}>",
                        "From: Alex McRitchie <amcritchie@gmail.com>")
    DeskCapture.ingest_raw(raw: own, s3_key: "resend/re_own.eml")

    item = DeskCaptureItem.find_by!(s3_key: "resend/re_own.eml")
    assert_equal "received", item.status, "the hand-forward path must keep working exactly as before"
    assert_equal 1, item.attachment_count
  end

  test "a second pull of the same message writes nothing twice" do
    pull("gm1" => deal_mime)

    assert_no_difference -> { DeskCaptureItem.count } do
      result = pull("gm1" => deal_mime)
      assert_equal 1, result.skipped
    end
  end

  test "the cursor advances only as far as a recorded row" do
    assert_nil DeskCaptureItem.gmail_cursor
    pull("gm1" => deal_mime)
    assert_equal 4242, DeskCaptureItem.gmail_cursor
  end
end
