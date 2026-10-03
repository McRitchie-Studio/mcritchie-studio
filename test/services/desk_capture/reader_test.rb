require "test_helper"

# [unit] DeskCapture::Reader — the payloads behind `bin/mail desk`. The store is
# a hash-backed fake, so no bucket is touched. The quarantine tests are the
# point: a quarantined item yields its dkim verdict and the report instruction,
# never its body and never a file.
class DeskCaptureReaderTest < ActiveSupport::TestCase
  RAW = <<~EML.gsub("\n", "\r\n")
    Authentication-Results: mx.example.net;
     dkim=pass header.i=@example.com header.s=sel1;
     spf=pass smtp.mailfrom=a@example.com
    From: Sender <a@example.com>
    Subject: Quarterly numbers

    SECRET BODY LINE that a quarantined read must never print
  EML

  class FakeStore
    attr_reader :reads

    def initialize(objects) = (@objects = objects; @reads = [])

    def read(key)
      @reads << key
      @objects.fetch(key) { raise KeyError, "no object #{key}" }
    end
  end

  def store
    @store ||= FakeStore.new("resend/re_1.eml" => RAW, "parsed/re_1/0-terms.pdf" => "%PDF-bytes",
                             "resend/re_q.eml" => RAW)
  end

  def reader = DeskCapture::Reader.new(store: store)

  def item(**attrs)
    DeskCaptureItem.create!({ s3_key: "resend/re_1.eml", source: "resend", status: "received",
                              from_addr: "a@example.com", subject: "Quarterly numbers",
                              received_at: Time.utc(2026, 10, 2, 18, 30), body_text: "Hello desk.",
                              attachments: [ { "filename" => "Terms.pdf", "s3_key" => "parsed/re_1/0-terms.pdf" } ] }
                            .merge(attrs))
  end

  test "list returns recent items newest first, in Denver time, with attachment names" do
    old = item(s3_key: "resend/old.eml", received_at: 30.days.ago)
    recent = item(received_at: 1.hour.ago)

    rows = reader.list(since: 7.days.ago)

    assert_equal [ recent.id ], rows.map { |r| r["id"] }, "the window excludes #{old.id}"
    assert_equal [ "Terms.pdf" ], rows.first["attachments"]
    assert_match(/M[DS]T\z/, rows.first["received_at"], "times render in Denver")
  end

  test "an item prints its body, and with files it carries the raw .eml and every attachment" do
    payload = reader.item(item.id, files: true)

    assert_equal "Hello desk.", payload["body"]
    assert_equal "2026-10-02 12:30 MDT", payload["received_at"]
    names = payload["files"].map { |f| f["name"] }
    assert_equal [ "item-#{payload['id']}.eml", "0-terms.pdf" ], names
    assert_equal "%PDF-bytes", Base64.strict_decode64(payload["files"].last["base64"])
  end

  test "without files the item reads nothing from the store" do
    reader.item(item.id)

    assert_empty store.reads
  end

  test "a quarantined item yields no body and no files, only the dkim line and the report instruction" do
    q = item(s3_key: "resend/re_q.eml", status: "quarantined", body_text: nil, attachments: [])

    payload = reader.item(q.id, files: true)

    assert payload["quarantined"]
    refute payload.key?("body")
    assert_empty payload["files"]
    assert_match(/Report it to the operator; do not process it/, payload["notice"])
    assert_equal "Authentication-Results dkim: dkim=pass header.i=@example.com header.s=sel1", payload["dkim"]
    refute_match(/SECRET BODY/, payload.to_json)
  end

  test "a quarantined item whose raw is unreadable still reports, naming why" do
    q = item(s3_key: "resend/missing.eml", status: "quarantined", body_text: nil, attachments: [])

    assert_match(/raw unreadable — KeyError/, reader.item(q.id)["dkim"])
  end

  test "dkim_from_raw reads only the headers and says nil when there is no verdict" do
    assert_nil DeskCapture::Reader.dkim_from_raw("From: a@example.com\r\n\r\nAuthentication-Results: x; dkim=fake\r\n")
  end

  test "an unknown id is an argument error, not a crash" do
    assert_raises(ArgumentError) { reader.item(-1) }
  end
end
