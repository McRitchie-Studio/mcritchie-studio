# Every minute in production (config/recurring.yml): the floor under
# bin/dispatcher. Posts ONE Discord alert per incident (a silent dispatcher, a
# routed message waiting over 10 minutes, a submitted card nobody started
# reviewing for 30, or a change card the build launcher could not start) and one
# recovery line, through
# AgentMessages::FloorAlert. Inert, with a log line, until the bot token and
# discord.ops_channel_id are set. docs/agents/agents/steffon/sops/agent-dispatcher.md.
class AgentDispatcherAlertJob < ApplicationJob
  queue_as :default

  def perform
    AgentMessages::FloorAlert.new.call
  end
end
