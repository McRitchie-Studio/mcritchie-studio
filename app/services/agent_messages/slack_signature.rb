module AgentMessages
  # Slack's request signing (v0): X-Slack-Signature is "v0=" + the hex
  # HMAC-SHA256, keyed by the app's signing secret (SLACK_SIGNING_SECRET), of
  # "v0:<X-Slack-Request-Timestamp>:<raw body>". A request older (or newer) than
  # MAX_SKEW is refused, so a captured request cannot be replayed later. The
  # comparison is constant-time. Pure: no secret, no signature valid.
  module SlackSignature
    VERSION = "v0".freeze
    MAX_SKEW = 5.minutes

    module_function

    def valid?(secret:, timestamp:, body:, signature:, now: Time.current)
      return false if secret.blank? || signature.blank? || !timestamp.to_s.match?(/\A\d+\z/)
      return false if (now.to_i - timestamp.to_i).abs > MAX_SKEW.to_i

      ActiveSupport::SecurityUtils.secure_compare(sign(secret: secret, timestamp: timestamp, body: body), signature.to_s)
    end

    def sign(secret:, timestamp:, body:)
      "#{VERSION}=#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, "#{VERSION}:#{timestamp}:#{body}")}"
    end
  end
end
