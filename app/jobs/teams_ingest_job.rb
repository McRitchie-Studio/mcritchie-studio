# Stores one Teams activity as an AgentMessage, or records a conversation
# reference from an install event (AgentMessages::TeamsIngest), off the
# webhook's request so the Bot Framework gets its answer at once
# (Webhooks::TeamsMessagesController). Idempotent: a retried delivery finds the
# row the first one stored.
class TeamsIngestJob < ApplicationJob
  queue_as :default

  def perform(activity)
    AgentMessages::TeamsIngest.new.call(activity)
  end
end
