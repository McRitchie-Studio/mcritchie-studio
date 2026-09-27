module Webhooks
  # POST /webhooks/resend/inbound — Resend's email.received webhook (svix-signed).
  #
  # The payload is metadata only; ingestion happens in a job that fetches the
  # full record. Verification is the whole security story here — this endpoint
  # is public by necessity, so an unsigned or stale request is dropped with a
  # 401 and nothing enqueued.
  class ResendInboundController < ActionController::Base
    include Webhooks::SvixSignature
    skip_before_action :verify_authenticity_token

    def create
      return head :unauthorized unless valid_signature?

      payload = JSON.parse(request.raw_post)
      if payload["type"] == "email.received"
        email_id = payload.dig("data", "email_id") || payload.dig("data", "id")
        DeskCaptureResendIngestJob.perform_later(email_id) if email_id.present?
      end
      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def valid_signature?
      valid_svix_signature?(ENV["RESEND_WEBHOOK_SECRET"])
    end
  end
end
