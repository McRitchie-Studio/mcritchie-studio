# Stores one Slack event as an AgentMessage (AgentMessages::SlackIngest), off the
# webhook's request so Slack gets its 200 inside three seconds
# (Webhooks::SlackEventsController). Idempotent: a retried delivery finds the
# row the first one stored.
class SlackIngestJob < ApplicationJob
  queue_as :default

  def perform(event, team_id, event_id = nil)
    AgentMessages::SlackIngest.new.call(event, team_id: team_id, event_id: event_id)
  end
end
