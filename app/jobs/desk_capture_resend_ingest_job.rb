# Ingest one Resend-received email into the desk queue. The webhook hands us
# an id; we fetch the record, pull the RAW MIME via its signed download_url
# (temporary — which is why the raw is immediately re-stored in the private
# desk bucket, our durable copy), and run the shared ingestion core. The
# existing Parser does all extraction, so both transports behave identically.
#
# THEN THE AGENT BRANCH (docs/agents/system/agent-message-loop.md, "Email"):
# AgentMessages::EmailIngest turns the mail into an agent message when it is
# for a CTO, and returns nil for everything else, which stays a desk capture
# exactly as before. It runs only here, on the Resend inbound: the Gmail read
# of alex@'s mailbox never reaches an agent. A failure there is logged and
# never undoes or retries the desk capture.
class DeskCaptureResendIngestJob < ApplicationJob
  queue_as :default

  def perform(email_id)
    key = "resend/#{email_id}.eml"
    return if DeskCaptureItem.exists?(s3_key: key)

    record = DeskCapture::ResendClient.fetch_received(email_id)
    download_url = record.dig("raw", "download_url") or raise "Resend record #{email_id} carries no raw.download_url"
    raw = DeskCapture::ResendClient.fetch_url(download_url)

    DeskCapture.store(key, raw, content_type: "message/rfc822")
    item = DeskCapture.ingest_raw(raw: raw, s3_key: key)
    to_agents(raw, item)
    item
  end

  private

  def to_agents(raw, item)
    AgentMessages::EmailIngest.new.call(raw, desk_item: item)
  rescue StandardError => e
    entry = ErrorLog.capture!(e)
    entry.update(target: item, target_name: "agent email ingest for desk item #{item&.id}") if entry && item
    Rails.logger.warn("[agent-messages] email ingest failed for desk item #{item&.id}: #{e.class}")
    nil
  end
end
