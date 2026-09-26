# Announce a queued /build request to the team's Discord #scratch-pad, so a new
# app request is seen without anyone watching the board.
#
# Runs after the request is queued (AppRequest#queue!), in the background: a
# Discord outage or a missing webhook must never cost a visitor their claim.
#
# The webhook is DISCORD_SCRATCH_PAD_WEBHOOK_URL. Unset, the job logs and does
# nothing — the request is still saved and still on the board and on
# /build/requests; only the ping is skipped. `discord_notified_at` is stamped on
# a successful post, so a retried job never announces the same request twice.
class AppRequestDiscordJob < ApplicationJob
  queue_as :default

  WEBHOOK_ENV = "DISCORD_SCRATCH_PAD_WEBHOOK_URL".freeze
  # The Studio accent violet (the chest badge's ring), so the post reads as a
  # /build event at a glance.
  EMBED_COLOR = 0x8E83FC

  def self.webhook_url = ENV[WEBHOOK_ENV].presence

  def perform(app_request_id)
    request_row = AppRequest.find_by(id: app_request_id)
    return if request_row.nil? || request_row.discord_notified_at.present?

    webhook = self.class.webhook_url
    if webhook.nil?
      Rails.logger.info("[app_request_discord] #{WEBHOOK_ENV} is unset; not announcing #{request_row.host}")
      return
    end

    ReleaseNotes::DiscordClient.deliver(embeds: [ self.class.embed(request_row) ], webhook_url: webhook)
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
      title: "🧱 New app request: #{request_row.host}",
      description: request_row.prompt.to_s,
      color: EMBED_COLOR,
      fields: fields,
      timestamp: (request_row.queued_at || Time.current).iso8601
    }
  end
end
