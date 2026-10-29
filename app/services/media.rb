# The messaging media the agents answer on: one adapter per medium, chosen by a
# message's `channel` (docs/agents/system/agent-message-loop.md, "Media"; the
# plan is .agents/epics/omnichannel-media.md).
#
#   Media.adapter("discord").deliver_reply(message)
#   Media.adapter(message.channel).typing(message, phase: "typing")
#
# A REPLY ALWAYS GOES BACK ON THE MEDIUM THE MESSAGE ARRIVED ON: the jobs resolve
# the adapter from the row's own `channel`, never from a configured default.
#
# The registry names every medium the hub speaks today. Adding one (Slack,
# Teams) is a Media::Adapter subclass and one line here; the jobs do not change.
module Media
  # Every medium's failure descends from this, so a job can retry on it without
  # naming a client: AgentMessages::DiscordBot::Error is one. A job's retry_on
  # Media::Error therefore retries exactly what it retried on before.
  class Error < StandardError; end

  # Media.adapter was asked for a medium the registry does not name.
  class UnknownMedium < Error; end

  # Medium key => adapter class name, resolved lazily so the autoloader (and a
  # code reload) owns the constants.
  REGISTRY = {
    "discord" => "Media::Discord",
    "email" => "Media::Email",
    "web" => "Media::Web"
  }.freeze

  module_function

  def keys = REGISTRY.keys

  def registered?(key) = REGISTRY.key?(key.to_s)

  # The adapter for `key` (a message's channel). Raises UnknownMedium for a key
  # the registry does not name; a caller that must stay quiet on one asks
  # `registered?` first.
  def adapter(key)
    name = REGISTRY.fetch(key.to_s) { raise UnknownMedium, "unknown medium #{key.inspect} (known: #{keys.join(', ')})" }
    name.constantize.new
  end

  # How a soul signs on every medium: a domain's front door as its registry
  # `reply_name` (Turf, not "Turf Monster"), else the Agent's name.
  def display_name(soul)
    AgentProposal.registry.reply_name(soul) || Agent.find_by(slug: soul)&.name.presence || soul.to_s.titleize
  end
end
