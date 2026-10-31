module Webhooks
  # POST /webhooks/teams/messages: the Bot Framework messaging endpoint for the
  # McRitchie Agents Teams bot (docs/agents/system/agent-message-loop.md, "Teams").
  #
  # Public by necessity, so THE JWT IS THE WHOLE SECURITY STORY: every request
  # carries `Authorization: Bearer <JWT>` signed by the Bot Connector, and
  # AgentMessages::TeamsAuth checks it (issuer, audience = our app id, the
  # signature against the Bot Framework JWKS, expiry, the serviceUrl claim
  # against the activity's, the key's msteams endorsement). A request that
  # fails gets a 401 (403 for a missing endorsement) and nothing is enqueued.
  # The token is never logged.
  #
  # DISABLED until credentials exist: with TEAMS_BOT_APP_ID or
  # TEAMS_BOT_APP_PASSWORD unset the endpoint answers 503 before reading the
  # body, so nothing is verified, stored or posted.
  #
  # ACK FAST. The request only verifies and enqueues TeamsIngestJob (a message,
  # or a conversationUpdate / installationUpdate that records where the bot may
  # post); the (channel, external_id) unique key makes a retried delivery a
  # no-op. Every other activity type is acknowledged and dropped.
  class TeamsMessagesController < ActionController::Base
    skip_before_action :verify_authenticity_token

    INGESTED = %w[message conversationUpdate installationUpdate].freeze
    MAX_BODY = 512.kilobytes

    def create
      return head :service_unavailable unless Media::Teams::Client.new.configured?
      return head :content_too_large if request.content_length.to_i > MAX_BODY

      activity = JSON.parse(request.raw_post)
      return head :bad_request unless activity.is_a?(Hash)

      result = AgentMessages::TeamsAuth.new(app_id: ENV[Media::Teams::Client::APP_ID_ENV])
                                       .verify(request.headers["Authorization"], activity)
      unless result.ok?
        Rails.logger.warn("[teams] refused a messaging request: #{result.reason}")
        return head result.status
      end

      TeamsIngestJob.perform_later(activity) if INGESTED.include?(activity["type"])
      head :ok
    rescue JSON::ParserError
      head :bad_request
    rescue StandardError => e
      ErrorLog.capture!(e)
      raise
    end
  end
end
