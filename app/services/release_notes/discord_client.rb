require "net/http"
require "openssl"

module ReleaseNotes
  class DiscordClient
    MissingWebhook = Class.new(StandardError)
    DeliveryError = Class.new(StandardError)
    Delivery = Struct.new(:status, :body, keyword_init: true)

    # Transport-level failures (DNS, refused, timeout, SSL, reset) — converted to
    # the typed DeliveryError so callers get one error contract instead of a
    # grab-bag of Net/Socket/SSL exceptions leaking out of `Net::HTTP.start`.
    TRANSPORT_ERRORS = [
      SocketError, SystemCallError, Timeout::Error, IOError,
      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
    ].freeze

    # Post a release-notes message: plain `content`, rich `embeds` (an array of
    # Discord embed hashes), or both. At least one must be present — the caller
    # (ReleaseNotes::Formatter#discord_payload) splats one or the other in.
    def self.deliver(content: nil, embeds: nil, webhook_url: nil)
      webhook_url = webhook_url.presence || self.webhook_url
      raise MissingWebhook, "Release notes webhook is not configured" if webhook_url.blank?

      new(webhook_url).deliver(content: content, embeds: embeds)
    end

    def self.webhook_url
      ENV["DISCORD_RELEASE_NOTES_WEBHOOK_URL"].presence || ENV["DISCORD_DEPLOY_WEBHOOK_URL"].presence
    end

    def initialize(webhook_url)
      @webhook_url = webhook_url
    end

    def deliver(content: nil, embeds: nil)
      uri = URI(@webhook_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = request_body(content: content, embeds: embeds).to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise DeliveryError, "Discord release notes notification failed: HTTP #{response.code}"
      end

      Delivery.new(status: response.code.to_i, body: response.body)
    rescue *TRANSPORT_ERRORS => e
      raise DeliveryError, "Discord release notes delivery failed: #{e.class}: #{e.message}"
    end

    private

    # Include only the parts Discord was given — a content-only message omits
    # `embeds` entirely (and vice versa), so neither half sends an empty key.
    def request_body(content:, embeds:)
      body = {}
      body[:content] = content if content.present?
      body[:embeds] = embeds if embeds.present?
      body
    end
  end
end
