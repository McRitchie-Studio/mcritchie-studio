# Every minute in production (config/recurring.yml): the floor under
# bin/dispatcher, through AgentMessages::FloorAlert. Posts ONE Discord alert per
# incident (a silent dispatcher, a routed message waiting over 10 minutes, a
# degraded harness on the Mac, and the per-card and backup kinds) and one
# recovery line, or one "flapping" line for an incident that keeps reopening;
# and emails a person once when an incident stays open 15 minutes or flaps, and
# once when it is steady. Discord is inert, with a log line, until the bot token
# and discord.ops_channel_id are set; the email is not.
# docs/agents/agents/steffon/sops/agent-dispatcher.md.
class AgentDispatcherAlertJob < ApplicationJob
  queue_as :default

  def perform
    AgentMessages::FloorAlert.new.call
  end
end
