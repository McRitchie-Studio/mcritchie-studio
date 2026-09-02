module Webhooks
  # POST /webhooks/resend/inbound — Resend's email.received webhook (svix-signed).
  #
  # The payload is metadata only; ingestion happens in a job that fetches the
  # full record. Verification is the whole security story here — this endpoint
  # is public by necessity, so an unsigned or stale request is dropped with a
  # 401 and nothing enqueued.
  class ResendInboundController < ActionController::Base
    skip_before_action :verify_authenticity_token
    TOLERANCE = 5.minutes

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

    # Svix scheme: secret "whsec_<base64>"; signed content "{id}.{timestamp}.{body}";
    # header "svix-signature: v1,<base64 hmac> [v1,<...>]" — any match passes.
    def valid_signature?
      secret = ENV["RESEND_WEBHOOK_SECRET"].to_s
      return false if secret.empty?

      msg_id = request.headers["svix-id"]
      timestamp = request.headers["svix-timestamp"]
      signatures = request.headers["svix-signature"].to_s
      return false if msg_id.blank? || timestamp.blank? || signatures.blank?
      return false if (Time.current.to_i - timestamp.to_i).abs > TOLERANCE

      key = Base64.decode64(secret.delete_prefix("whsec_"))
      expected = Base64.strict_encode64(
        OpenSSL::HMAC.digest("SHA256", key, "#{msg_id}.#{timestamp}.#{request.raw_post}")
      )
      signatures.split.any? do |candidate|
        version, sig = candidate.split(",", 2)
        version == "v1" && sig.present? &&
          ActiveSupport::SecurityUtils.secure_compare(sig, expected)
      end
    end
  end
end
