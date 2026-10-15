# Every 15 minutes in production (config/recurring.yml), and on demand from the
# Refresh channels button on /admin/report_destinations: mirror each configured
# guild's channels and active threads into discord_channels
# (DiscordDirectory::Sync, docs/agents/system/report-destinations.md).
#
# Inert until configured. With no DISCORD_AGENT_BOT_TOKEN, or no guild in
# config/agent_routes.yml, it does nothing and says so ONCE per process, so a
# dyno without the bot logs one line, not one every 15 minutes. It returns the
# Sync::Summary, or nil when idle, for the button's flash.
class DiscordChannelSyncJob < ApplicationJob
  queue_as :default

  class_attribute :announced_idle, default: false

  # A guild or thread list Discord refused (a 403 on a guild the bot left, a 429),
  # written to ErrorLog so a directory that stopped refreshing is visible.
  SyncFailed = Class.new(StandardError)

  def perform
    reason = idle_reason
    return announce_idle(reason) if reason

    summary = DiscordDirectory::Sync.new.call
    Rails.logger.info("[discord-channels] sync: #{summary}") if summary.archived.positive? || !summary.ok? || summary.notes.any?
    receipt_failure(summary) unless summary.ok?
    summary
  end

  def self.idle_reason
    return "#{AgentMessages::DiscordBot::TOKEN_ENV} is unset" unless AgentMessages::DiscordBot.configured?
    return "config/agent_routes.yml lists no Discord guild" if DiscordDirectory::Sync.guild_ids.empty?

    nil
  end

  private

  def idle_reason = self.class.idle_reason

  # One ErrorLog row per outage (a dead token's 401 repeats every run); a good sync's synced_at re-arms it.
  def receipt_failure(summary)
    message = "Discord channel sync: #{summary.errors.join('; ')[0, 900]}"
    since = DiscordChannel.maximum(:synced_at)
    seen = ErrorLog.where(message: message)
    return if (since ? seen.where("created_at > ?", since) : seen).exists?
    ErrorLog.capture!(SyncFailed.new(message))
  end

  def announce_idle(reason)
    return if self.class.announced_idle

    self.class.announced_idle = true
    Rails.logger.info("[discord-channels] sync idle: #{reason}; no channel is read until it is set")
    nil
  end
end
