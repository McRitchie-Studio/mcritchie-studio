require "test_helper"

# [unit] The Resend ingest job — fetch record, fetch raw, store durably, run
# the shared ingestion core. HTTP and S3 are stubbed at the seams the job
# actually calls, so what's proven is the wiring and the idempotency.
class DeskCaptureResendIngestJobTest < ActiveSupport::TestCase
  def raw_fixture
    File.read(Rails.root.join("test/fixtures/files/desk_sample.eml"))
  end

  # Shaped like Resend's GET /emails/receiving/{id} response: the signed
  # download URL is NESTED under "raw" (raw.download_url), never top-level.
  def resend_record
    { "raw" => { "download_url" => "https://signed.example/raw", "expires_at" => 1.hour.from_now.iso8601 } }
  end

  def with_stubs(record:, raw:, stored: [])
    originals = {
      fetch_received: DeskCapture::ResendClient.method(:fetch_received),
      fetch_url: DeskCapture::ResendClient.method(:fetch_url),
      store: DeskCapture.method(:store)
    }
    DeskCapture::ResendClient.define_singleton_method(:fetch_received) { |_id| record }
    DeskCapture::ResendClient.define_singleton_method(:fetch_url) { |_url| raw }
    DeskCapture.define_singleton_method(:store) { |key, _body, **| stored << key; key }
    yield
  ensure
    DeskCapture::ResendClient.define_singleton_method(:fetch_received, originals[:fetch_received])
    DeskCapture::ResendClient.define_singleton_method(:fetch_url, originals[:fetch_url])
    DeskCapture.define_singleton_method(:store, originals[:store])
  end

  test "ingests a received email end to end: raw stored, item created, attachments extracted" do
    stored = []
    with_stubs(record: resend_record, raw: raw_fixture, stored: stored) do
      DeskCaptureResendIngestJob.perform_now("re_test1")
    end

    item = DeskCaptureItem.find_by!(s3_key: "resend/re_test1.eml")
    assert_equal "received", item.status
    assert_equal "amcritchie@gmail.com", item.from_addr
    assert_equal "commercial-welding-llc", item.entity_hint
    assert_equal 1, item.attachment_count
    assert_includes stored, "resend/re_test1.eml", "the temporary Resend URL must be re-stored durably"
    assert stored.any? { |k| k.start_with?("parsed/re_test1/") }, "attachments extract into parsed/"
  end

  test "re-delivery of the same email id creates nothing twice" do
    with_stubs(record: resend_record, raw: raw_fixture) do
      DeskCaptureResendIngestJob.perform_now("re_test2")
      assert_no_difference -> { DeskCaptureItem.count } do
        DeskCaptureResendIngestJob.perform_now("re_test2")
      end
    end
  end

  test "a stranger's mail quarantines with attachments left unextracted" do
    stranger_raw = raw_fixture.sub("From: Alex McRitchie <amcritchie@gmail.com>",
                                   "From: Broker <broker@clearlyacquired.com>")
    stored = []
    with_stubs(record: resend_record, raw: stranger_raw, stored: stored) do
      DeskCaptureResendIngestJob.perform_now("re_test3")
    end

    item = DeskCaptureItem.find_by!(s3_key: "resend/re_test3.eml")
    assert_equal "quarantined", item.status
    assert_equal 0, item.attachment_count
    assert_nil item.body_text
    refute stored.any? { |k| k.start_with?("parsed/") }, "quarantined attachments must never extract"
  end
end
