# Ingest one Resend-received email into the desk queue. The webhook hands us
# an id; we fetch the record, pull the RAW MIME via its signed download_url
# (temporary — which is why the raw is immediately re-stored in the private
# desk bucket, our durable copy), and run the shared ingestion core. The
# existing Parser does all extraction, so both transports behave identically.
class DeskCaptureResendIngestJob < ApplicationJob
  queue_as :default

  def perform(email_id)
    key = "resend/#{email_id}.eml"
    return if DeskCaptureItem.exists?(s3_key: key)

    record = DeskCapture::ResendClient.fetch_received(email_id)
    download_url = record.dig("raw", "download_url") or raise "Resend record #{email_id} carries no raw.download_url"
    raw = DeskCapture::ResendClient.fetch_url(download_url)

    DeskCapture.store(key, raw, content_type: "message/rfc822")
    DeskCapture.ingest_raw(raw: raw, s3_key: key)
  end
end
