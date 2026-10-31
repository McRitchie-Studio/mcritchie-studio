module AgentMessages
  # The `slack:` block of config/agent_routes.yml: which workspace is read, the
  # app's own bot user, the owner's Slack user, which souls a Slack message is
  # for (one or several: #addressed, #everyone?), and which souls may answer in
  # which channel (CLEARANCE, #cleared?)
  # (docs/agents/system/agent-message-loop.md, "Slack"). Pure: it reads
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

    attr_reader :team_id, :bot_user_id, :owner_user_id, :mention_soul, :souls, :core_souls, :recognized

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
      # { soul => [names] } a name may address but no dispatcher serves on Slack:
      # routed so the message is held ("soul cannot answer yet"), never left to
      # fall through to a channel default another soul would answer. Never
      # in #routed_souls.
      @recognized = (config["recognized"] || {}).to_h do |soul, spec|
        [ soul.to_s, Array((spec || {})["names"]).map { |n| n.to_s.strip }.reject(&:empty?) ]
      end.except(*@souls.keys)
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

    # Every configured channel override, in config order.
    def channels = @overrides.values

    # The id of the configured channel named `name` ("turf-monster"), or nil.
    def channel_id_named(name) = channels.find { |c| c.name == name.to_s }&.channel_id

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

    # Rule 1: the soul the text opens by addressing, or nil: the first of
    # #addressed. A served soul wins a tie with a recognized one.
    def named(text) = addressed(text).first

    # Rule 1, every soul the text opens by addressing, in the order named, or []:
    #   one name    "Avi, …"  "Avi: …"  "Hi Avi, …"  "@Avi …" (EmailRoutes.addressed_to?)
    #   a list      "Avi and Mason, …"  "Avi, Mason: …"  "Avi, Mason and Carl …"
    #               "@Avi @Mason …"  "@Avi and @Mason …"
    # A list is an address only when it is closed by "," or ":", when every name
    # in it carries an @, or when it has a comma and ends "and <name>" (the
    # "A, B and C …" form). So "Avi and Mason are right" addresses nobody (as
    # before), and "Avi, Mason said …" addresses Avi alone: the longest list
    # that is an address wins, else the one-name rule. A name mid-sentence is
    # never an address.
    def addressed(text)
      line = opening_line(text)
      list = addressed_list(line)
      return list if list

      one = @souls.merge(@recognized).find { |_soul, names| EmailRoutes.addressed_to?(line, names) }&.first
      one ? [ one ] : []
    end

    # Whether the text opens by addressing everyone: "Everyone, …", "All: …",
    # "Agents, …", "Hi everybody, …", or Slack's own <!everyone>, <!channel>,
    # <!here>. SlackIngest fans such a message to #everyone_in.
    def everyone?(text)
      line = opening_line(text)
      line.match?(BROADCAST) || line.match?(EVERYONE)
    end

    # The souls an everyone address reaches in `channel_id`: every soul served on
    # Slack (#routed_souls, config order) that is cleared there. Recognized-only
    # souls are never included: they cannot answer.
    def everyone_in(channel_id) = routed_souls.select { |soul| cleared?(channel_id, soul) }

    # Whether `soul` is served on Slack (has slack.souls names, or is the mention
    # soul or a channel default). A recognized-only soul is not: it cannot answer yet.
    def answers?(soul) = routed_souls.include?(soul.to_s)

    def unanswerable_reason(soul)
      "soul cannot answer yet: #{soul} is recognized by name on Slack but no dispatcher serves it " \
        "(config/agent_routes.yml slack.recognized; add it to slack.souls to let it answer)"
    end

    # Every soul this block can route to: the named souls, the mention soul and
    # each channel default (bin/dispatcher serves them: AgentMailbox.routed_souls).
    def routed_souls
      (@souls.keys + [ @mention_soul ] + @overrides.values.map(&:default_soul)).compact.uniq
    end

    private

    EVERYONE_WORDS = %w[everyone everybody all agents].freeze
    EVERYONE = /\A#{EmailRoutes::GREETING}@?(?:#{EVERYONE_WORDS.join('|')})\s*[,:!]/i
    BROADCAST = /\A<!(?:everyone|channel|here)(?:\|[^>]*)?>/
    # Between two names of a list: ", and", ",", "and", "&", or bare space
    # before an @name.
    LIST_SEPARATOR = /\A(?:\s*,\s*and\s+|\s*,\s*|\s+and\s+|\s*&\s*|\s+(?=@))/i
    CLOSED = /\A\s*[,:]/

    # The first non-blank line, past a leading @-mention of the app.
    def opening_line(text) = strip_leading_bot_mention(text).lines.map(&:strip).find(&:present?).to_s

    # The souls a list of two or more names at the start of `line` addresses
    # (see #addressed), or nil when it opens with no such list.
    def addressed_list(line)
      pos = line[/\A#{EmailRoutes::GREETING}/].to_s.length
      found = [] # { soul:, at:, separator: (the kind before it), ends: }
      separator = nil
      while (name = name_at(line, pos))
        soul, at, length = name
        pos += length
        found << { soul: soul, at: at, separator: separator, ends: pos }
        sep = line[pos..].to_s[LIST_SEPARATOR]
        break unless sep && name_at(line, pos + sep.length)

        separator = separator_kind(sep)
        pos += sep.length
      end
      found.length.downto(2) do |k|
        list = found.first(k)
        return list.map { |entry| entry[:soul] }.uniq if list_address?(line, list)
      end
      nil
    end

    def separator_kind(sep)
      comma = sep.include?(",")
      conj = sep.match?(/and|&/i)
      return :comma_and if comma && conj
      return :comma if comma

      conj ? :and : :space
    end

    # Closed by "," or ":", every name an @name, or the "A, B and C" form.
    def list_address?(line, list)
      kinds = list.drop(1).map { |entry| entry[:separator] }
      return true if line[list.last[:ends]..].to_s.match?(CLOSED)
      return true if list.all? { |entry| entry[:at] }

      kinds.intersect?(%i[comma comma_and]) && %i[and comma_and].include?(kinds.last)
    end

    # [soul, at?, length] of the longest name that starts `line` at `pos` and is
    # a whole word, or nil. Served souls first, so a served soul wins a tie.
    def name_at(line, pos)
      rest = line[pos..].to_s
      at = rest.start_with?("@")
      body = at ? rest[1..] : rest
      best = nil
      @souls.merge(@recognized).each do |soul, names|
        names.each do |name|
          next unless body.match?(/\A#{Regexp.escape(name)}(?![[:alnum:]_])/i)
          next if best && best[2] >= name.length + (at ? 1 : 0)

          best = [ soul, at, name.length + (at ? 1 : 0) ]
        end
      end
      best
    end

    def soul_list(value) = Array(value).map { |s| s.to_s.strip }.reject(&:empty?).uniq
  end
end
