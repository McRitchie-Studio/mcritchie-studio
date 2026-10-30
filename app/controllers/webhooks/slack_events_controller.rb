module Webhooks
  # POST /webhooks/slack/events — the Slack Events API for the McRitchie Agents
  # app (docs/agents/system/agent-message-loop.md, "Slack").
  #
  # Public by necessity, so the SIGNATURE IS THE WHOLE SECURITY STORY: an
  # unsigned, mis-signed or stale request (AgentMessages::SlackSignature, over the
  # raw body with SLACK_SIGNING_SECRET) gets a 401 and nothing is enqueued, and
  # that includes the url_verification handshake.
  #
  # ACK FAST. Slack retries an event it has no 2xx for within three seconds, so
  # the request only verifies and enqueues SlackIngestJob; the job stores the
  # message (AgentMessages::SlackIngest), and the (channel, external_id) unique
  # key makes a retried delivery a no-op.
  class SlackEventsController < ActionController::Base
    skip_before_action :verify_authenticity_token

    def create
      body = request.raw_post
      return head :unauthorized unless signed?(body)

      payload = JSON.parse(body)
      case payload["type"]
      when "url_verification"
        render json: { challenge: payload["challenge"].to_s }
      when "event_callback"
        event = payload["event"]
        SlackIngestJob.perform_later(event, payload["team_id"].to_s, payload["event_id"].to_s) if event.is_a?(Hash)
        head :ok
      else
        head :ok
      end
    rescue JSON::ParserError
      head :bad_request
    rescue StandardError => e
      ErrorLog.capture!(e)
      raise
    end

    private

    def signed?(body)
      AgentMessages::SlackSignature.valid?(secret: ENV[Media::Slack::SIGNING_SECRET_ENV],
                                           timestamp: request.headers["X-Slack-Request-Timestamp"],
                                           signature: request.headers["X-Slack-Signature"], body: body)
    end
  end
end
