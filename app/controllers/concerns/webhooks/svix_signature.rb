module Webhooks
  # Resend signs its webhooks with Svix. Every Resend endpoint has its own
  # secret, so the including controller names the one it checks against.
  #
  # Svix scheme: secret "whsec_<base64>"; signed content "{id}.{timestamp}.{body}";
  # header "svix-signature: v1,<base64 hmac> [v1,<...>]" — any match passes. A
  # request older or newer than TOLERANCE is refused, so a captured one cannot
  # be replayed later.
  module SvixSignature
    TOLERANCE = 5.minutes

    private

    def valid_svix_signature?(secret)
      secret = secret.to_s
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
