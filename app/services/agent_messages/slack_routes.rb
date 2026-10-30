module AgentMessages
  # The `slack:` block of config/agent_routes.yml: which workspace is read, the
  # app's own bot user, the owner's Slack user, and which soul a Slack message
  # is for (docs/agents/system/agent-message-loop.md, "Slack"). Pure: it reads
  # text and ids and touches nothing. The THREAD rule needs the database, so
  # AgentMessages::SlackIngest applies it between #named and #mention_soul.
  class SlackRoutes
    PATH = Rails.root.join("config/agent_routes.yml")

    # `souls` is nil when the channel names no clearance (every soul may answer
    # there, as before clearance existed), else the souls it lists; `open` admits
    # every soul.
    Override = Struct.new(:channel_id, :name, :default_soul, :ignore, :open, :souls, keyword_init: true) do
      def ignore? = ignore == true

      def open? = open == true

      # Whether this channel limits who may answer in it.
      def guarded? = !open? && !souls.nil?
    end

    attr_reader :team_id, :bot_user_id, :owner_user_id, :mention_soul, :souls, :core_souls

    def self.load(path = PATH)
      new((YAML.safe_load_file(path, aliases: false) || {})["slack"] || {})
    end

    class << self
      def current = @current ||= load

      attr_writer :current

      def reset! = @current = nil
    end

    def initialize(config)
      config ||= {}
      @team_id = config["team_id"].to_s.strip.presence
      @bot_user_id = config["bot_user_id"].to_s.strip.presence
      @owner_user_id = config["owner_user_id"].to_s.strip.presence
      @mention_soul = config["mention_soul"].to_s.strip.presence
      # { soul => [names] }, in config order (the first soul named wins a tie).
      @souls = (config["souls"] || {}).to_h do |soul, spec|
        [ soul.to_s, Array((spec || {})["names"]).map { |n| n.to_s.strip }.reject(&:empty?) ]
      end
      # Cleared on every guarded channel (the McRitchie Studio agents, who move
      # all around), on top of each channel's own `souls:`.
      @core_souls = soul_list(config["core_souls"])
      @overrides = (config["channels"] || {}).to_h do |id, spec|
        spec ||= {}
        listed = spec.key?("souls") ? soul_list(spec["souls"]) : nil
        [ id.to_s, Override.new(channel_id: id.to_s, name: spec["name"].to_s.presence,
                                default_soul: spec["default_soul"].to_s.strip.presence, ignore: spec["ignore"] == true,
                                open: spec["open"] == true, souls: listed) ]
      end
    end

    # A workspace other than ours is never read. With no team_id configured,
    # nothing is.
    def team?(team_id) = @team_id.present? && team_id.to_s == @team_id

    def override(channel_id) = @overrides[channel_id.to_s]

    def ignored?(channel_id) = override(channel_id)&.ignore? || false

    def default_soul(channel_id) = override(channel_id)&.default_soul

    def channel_name(channel_id) = override(channel_id)&.name

    # CLEARANCE: whether `soul` may answer in `channel_id`. A channel with no
    # clearance config (no `souls:`, no `open: true`), a DM and an unknown
    # channel admit every soul; `open: true` admits every soul; otherwise only
    # core_souls plus the channel's own `souls:`. SlackIngest stores a message
    # routed to an uncleared soul `held`, never answered.
    def cleared?(channel_id, soul)
      entry = override(channel_id)
      return true unless entry&.guarded?

      cleared_souls(channel_id).include?(soul.to_s)
    end

    # The souls cleared in a guarded channel (core first), or nil when the
    # channel admits every soul.
    def cleared_souls(channel_id)
      entry = override(channel_id)
      return nil unless entry&.guarded?

      (@core_souls + entry.souls).uniq
    end

    # Why a message for `soul` in `channel_id` is held, for its `held` event.
    def clearance_reason(channel_id, soul)
      where = channel_name(channel_id).present? ? "##{channel_name(channel_id)}" : "channel #{channel_id}"
      "soul not cleared for this channel: #{soul} may not answer in #{where}; " \
        "cleared there: #{cleared_souls(channel_id).join(', ').presence || 'nobody'} (config/agent_routes.yml slack.channels)"
    end

    # Whether `text` mentions the app's own bot user (<@U…> or <@U…|name>).
    def mentions_bot?(text)
      @bot_user_id.present? && text.to_s.match?(/<@#{Regexp.escape(@bot_user_id)}(?:\|[^>]*)?>/)
    end

    # The text with a LEADING mention of the app removed, so "@McRitchie Agents
    # Avi, …" is read as "Avi, …".
    def strip_leading_bot_mention(text)
      return text.to_s.strip if @bot_user_id.blank?

      text.to_s.strip.sub(/\A<@#{Regexp.escape(@bot_user_id)}(?:\|[^>]*)?>[\s,:]*/, "")
    end

    # Rule 1: the soul the text opens by addressing, or nil.
    def named(text)
      line = strip_leading_bot_mention(text).lines.map(&:strip).find(&:present?).to_s
      @souls.find { |_soul, names| EmailRoutes.addressed_to?(line, names) }&.first
    end

    # Every soul this block can route to: the named souls, the mention soul and
    # each channel default (bin/dispatcher serves them: AgentMailbox.routed_souls).
    def routed_souls
      (@souls.keys + [ @mention_soul ] + @overrides.values.map(&:default_soul)).compact.uniq
    end

    private

    def soul_list(value) = Array(value).map { |s| s.to_s.strip }.reject(&:empty?).uniq
  end
end
