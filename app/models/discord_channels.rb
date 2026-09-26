# The team's Discord channels this app posts to, as LANES. Two today, split by
# who the message comes from, because each will want its own bot filters:
#
#   external — messages from the OUTSIDE WORLD: /build app requests, and later
#              anything a customer or visitor sends in.
#   internal — the team talking to itself: agents, releases, operators.
#
# A lane's webhook URL is a secret, so it lives in ENV (set on Heroku from the
# 1Password item discord.webhooks, field `op_field`) and never in this file.
# An unset lane answers nil: callers skip the post and log, and nothing else
# breaks — a missing webhook must never cost a visitor anything.
module DiscordChannels
  LANES = {
    external: {
      env: "DISCORD_EXTERNAL_WEBHOOK_URL",
      channel: "external-communication",
      op_field: "external-communication-webhook",
      purpose: "Messages from the outside world: app requests from /build, and inbound customer messages."
    },
    internal: {
      env: "DISCORD_INTERNAL_WEBHOOK_URL",
      channel: "internal-communication",
      op_field: "internal-communication-webhook",
      purpose: "Internal communication between the team and its agents."
    }
  }.freeze

  class UnknownLane < ArgumentError; end

  module_function

  def lane(name)
    LANES.fetch(name.to_sym) { raise UnknownLane, "unknown Discord lane #{name.inspect} — known: #{LANES.keys.join(', ')}" }
  end

  # The lane's webhook URL, or nil when it is not configured.
  def webhook_url(name) = ENV[lane(name).fetch(:env)].presence

  def configured?(name) = !webhook_url(name).nil?

  # "#external-communication" — for copy on pages and in logs. Never the URL.
  def channel_label(name) = "##{lane(name).fetch(:channel)}"
end
