# Every 15 minutes in production (config/recurring.yml), and on demand from the
# Refresh channels button on /admin/report_destinations: mirror each configured
# guild's channels and active threads into discord_channels
# (DiscordChannels::Sync, docs/agents/system/report-destinations.md).
#
# Inert until configured. With no DISCORD_AGENT_BOT_TOKEN, or no guild in
# config/agent_routes.yml, it does nothing and says so ONCE per process, so a
# dyno without the bot logs one line, not one every 15 minutes. It returns the
# Sync::Summary, or nil when idle, for the button's flash.
class DiscordChannelSyncJob < ApplicationJob
  queue_as :default

  class_attribute :announced_idle, default: false

  def perform
    reason = idle_reason
    return announce_idle(reason) if reason

    summary = DiscordChannels::Sync.new.call
    Rails.logger.info("[discord-channels] sync: #{summary}") if summary.archived.positive? || !summary.ok? || summary.notes.any?
    summary
  end

  def self.idle_reason
    return "#{AgentMessages::DiscordBot::TOKEN_ENV} is unset" unless AgentMessages::DiscordBot.configured?
    return "config/agent_routes.yml lists no Discord guild" if DiscordChannels::Sync.guild_ids.empty?

    nil
  end

  private

  def idle_reason = self.class.idle_reason

  def announce_idle(reason)
    return if self.class.announced_idle

    self.class.announced_idle = true
    Rails.logger.info("[discord-channels] sync idle: #{reason}; no channel is read until it is set")
    nil
  end
end
