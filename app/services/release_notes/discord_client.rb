require "net/http"

module ReleaseNotes
  class DiscordClient
    MissingWebhook = Class.new(StandardError)
    DeliveryError = Class.new(StandardError)
    Delivery = Struct.new(:status, :body, keyword_init: true)

    def self.deliver(content:, webhook_url: nil)
      webhook_url = webhook_url.presence || self.webhook_url
      raise MissingWebhook, "Release notes webhook is not configured" if webhook_url.blank?

      new(webhook_url).deliver(content: content)
    end

    def self.webhook_url
      ENV["DISCORD_RELEASE_NOTES_WEBHOOK_URL"].presence || ENV["DISCORD_DEPLOY_WEBHOOK_URL"].presence
    end

    def initialize(webhook_url)
      @webhook_url = webhook_url
    end

    def deliver(content:)
      uri = URI(@webhook_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = { content: content }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise DeliveryError, "Discord release notes notification failed: HTTP #{response.code}"
      end

      Delivery.new(status: response.code.to_i, body: response.body)
    end
  end
end
