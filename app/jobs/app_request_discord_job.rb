# Announce a queued /build request to the team's Discord, on the EXTERNAL lane
# (#external-communication: messages from the outside world), so a new app
# request is seen without anyone watching the board. Where it posts is the
# app_requests home in config/agent_media.yml (discord #external, the
# DISCORD_EXTERNAL_WEBHOOK_URL lane of DiscordChannels), through Media.post.
#
# Runs after the request is queued (AppRequest#queue!), in the background: a
# Discord outage or a missing webhook must never cost a visitor their claim.
#
# The webhook is the home's (the external lane's). Unset, the job logs and
# does nothing — the request is still saved and still on the board and on
# /build/requests; only the ping is skipped. `discord_notified_at` is stamped on
# a successful post, so a retried job never announces the same request twice.
class AppRequestDiscordJob < ApplicationJob
  queue_as :default

  LANE = :external
  # The Studio accent violet (the chest badge's ring), so the post reads as a
  # /build event at a glance.
  EMBED_COLOR = 0x8E83FC

  def self.home = Media.home(purpose: :app_requests)

  def self.webhook_url = home&.webhook_url

  def perform(app_request_id)
    request_row = AppRequest.find_by(id: app_request_id)
    return if request_row.nil? || request_row.discord_notified_at.present?

    home = self.class.home
    unless home&.channel? && (home.medium != "discord" || home.webhook_url)
      unset = home ? home.webhook_envs.join(" / ").presence || home.label : "config/agent_media.yml app_requests"
      Rails.logger.info("[app_request_discord] #{unset} is unset; not announcing #{request_row.host} to #{home&.label}")
      return
    end

    Media.post(home, embeds: [ self.class.embed(request_row) ])
    request_row.update_column(:discord_notified_at, Time.current)
  end

  # The message, built separately so it can be tested without a network.
  def self.embed(request_row)
    base = "https://#{ENV.fetch('APP_HOST', 'mcritchie.studio')}"
    requester = request_row.user
    who = requester ? [ requester.name.presence, requester.email ].compact.join(" · ") : "unknown"
    fields = [
      { name: "App address", value: request_row.host.to_s, inline: true },
      { name: "Tier", value: request_row.tier.to_s.titleize, inline: true },
      { name: "Requested by", value: who, inline: false }
    ]
    fields << { name: "Board card", value: "#{base}/tasks/#{request_row.task_slug}", inline: false } if request_row.task_slug
    fields << { name: "All requests", value: "#{base}/build/requests", inline: false }
    {
      title: "🧱 New #{request_row.showcase? ? 'showcase ' : ''}app request: #{request_row.host}",
      description: request_row.prompt.to_s,
      color: EMBED_COLOR,
      fields: fields,
      timestamp: (request_row.queued_at || Time.current).iso8601
    }
  end
end
