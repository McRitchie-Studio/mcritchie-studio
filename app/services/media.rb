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

  # Media.post was handed no home: every medium on the walk was unusable.
  class NoHome < Error; end

  # Medium key => adapter class name, resolved lazily so the autoloader (and a
  # code reload) owns the constants. Teams is registered but disabled: every
  # method raises NotImplementedError (Media::Teams).
  REGISTRY = {
    "discord" => "Media::Discord",
    "email" => "Media::Email",
    "web" => "Media::Web",
    "teams" => "Media::Teams"
  }.freeze

  module_function

  def keys = REGISTRY.keys

  def registered?(key) = REGISTRY.key?(key.to_s)

  # Whether a registered medium can do `capability` (:reply, :typing, :post)
  # today. False for an unregistered one, and for Media::Teams on everything.
  def supports?(key, capability)
    registered?(key) && REGISTRY.fetch(key.to_s).constantize.new.supports?(capability)
  end

  # The adapter for `key` (a message's channel). Raises UnknownMedium for a key
  # the registry does not name; a caller that must stay quiet on one asks
  # `registered?` first.
  def adapter(key)
    name = REGISTRY.fetch(key.to_s) { raise UnknownMedium, "unknown medium #{key.inspect} (known: #{keys.join(', ')})" }
    name.constantize.new
  end

  # The HOME a standalone post goes to (config/agent_media.yml): the first of
  # purpose → soul → app → defaults with an entry gives the medium and channel;
  # a medium that is not usable (block missing or disabled, no adapter, or an
  # adapter that cannot :post) is skipped for its `fallback`, keeping the same
  # channel name, and the walk is logged once per process. nil only when every
  # medium on the walk is unusable.
  #
  #   Media.home(purpose: :floor_alert)                 # => discord #ops
  #   Media.home(purpose: :reports, app: "turf_monster") # => discord, no channel
  #
  # Never used for a reply: a reply goes back on the message's own medium.
  def home(purpose:, app: nil, soul: nil, config: Config.current)
    source, entry = home_entry(config, purpose: purpose, soul: soul, app: app)
    medium = (entry["medium"].to_s.presence || config.default_medium).to_s
    channel = entry.key?("channel") ? entry["channel"]&.to_s.presence : config.defaults["channel"].to_s.presence
    fell_from = []
    until usable_medium?(config, medium)
      fell_from << medium
      medium = config.fallback(medium).to_s
      next unless medium.empty? || fell_from.include?(medium)

      note_fallback!(source, fell_from, nil)
      return nil
    end
    note_fallback!(source, fell_from, medium) if fell_from.any?
    Home.new(medium: medium, channel: channel, spec: config.channel(medium, channel), source: source, fell_from: fell_from)
  end

  # A standalone post to `home` on its medium (Media::Adapter#post). Raises
  # NoHome for a nil home.
  def post(home, **payload)
    raise NoHome, "no usable medium for this post (config/agent_media.yml)" if home.nil?

    adapter(home.medium).post(home, **payload)
  end

  def usable_medium?(config, key)
    !key.to_s.empty? && config.enabled?(key) && supports?(key, :post)
  end

  def home_entry(config, purpose:, soul:, app:)
    [ [ "purposes", "purpose", purpose ], [ "souls", "soul", soul ], [ "apps", "app", app ] ].each do |level, label, name|
      entry = config.entry(level, name)
      return [ "#{label}:#{name}", entry ] if entry
    end
    [ "defaults", {} ]
  end

  # One log line per (source, walk) per process: a misconfigured medium must
  # not write a line on every floor-alert minute.
  def note_fallback!(source, fell_from, landed)
    @fallbacks_noted ||= Set.new
    return unless @fallbacks_noted.add?([ source, fell_from, landed ])

    where = landed ? "falling back to #{landed}" : "and nothing to fall back to; nothing is posted"
    Rails.logger.warn("[media] #{source}: #{fell_from.join(' → ')} is not usable (config/agent_media.yml), #{where}")
  end

  def reset_fallback_notes! = @fallbacks_noted = nil

  private_class_method :home_entry, :note_fallback!

  # How a soul signs on every medium: a domain's front door as its registry
  # `reply_name` (Turf, not "Turf Monster"), else the Agent's name.
  def display_name(soul)
    AgentProposal.registry.reply_name(soul) || Agent.find_by(slug: soul)&.name.presence || soul.to_s.titleize
  end
end
