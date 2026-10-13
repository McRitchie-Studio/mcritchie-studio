# Every minute in production (config/recurring.yml): read the allow-listed
# Discord channels and store new messages for the agents
# (AgentMessages::DiscordPoll, docs/agents/system/agent-message-loop.md).
#
# Inert until configured. With no DISCORD_AGENT_BOT_TOKEN, or no channel in
# config/agent_routes.yml, it does nothing and says so ONCE per process, so a
# dyno without the bot logs one line, not one a minute.
class AgentMessageDiscordPollJob < ApplicationJob
  queue_as :default

  class_attribute :announced_idle, default: false

  def perform
    routes = AgentMessages::Routes.load
    reason = idle_reason(routes)
    return announce_idle(reason) if reason

    summary = AgentMessages::DiscordPoll.new(routes: routes).call
    if summary.stored.positive? || summary.errors.any?
      Rails.logger.info("[agent-messages] discord poll: #{summary.channels} channel(s), #{summary.stored} stored, " \
                        "#{summary.skipped} skipped#{summary.errors.any? ? ", errors: #{summary.errors.join('; ')}" : ''}")
    end
    summary
  end

  private

  def idle_reason(routes)
    return "#{AgentMessages::DiscordBot::TOKEN_ENV} is unset" unless AgentMessages::DiscordBot.configured?
    return "config/agent_routes.yml lists no Discord channel" if routes.channels.empty?

    nil
  end

  def announce_idle(reason)
    return if self.class.announced_idle

    self.class.announced_idle = true
    Rails.logger.info("[agent-messages] discord poll idle: #{reason}; nothing is read until it is set")
    nil
  end
end
