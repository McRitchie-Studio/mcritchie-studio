module AgentMessages
  # config/agent_routes.yml, read into a shape the poll, the gateway and the
  # router can ask: which guilds are in scope, which soul a mention names, and
  # which channels carry an override. Every id is a String.
  #
  # THE GUILD IS THE BOUNDARY. Every text channel, thread and forum post in a
  # listed guild is in scope with no per-channel entry; a guild that is not
  # listed is ignored even when the bot is a member of it. A channel entry is an
  # optional OVERRIDE: `default_soul` routes its unaddressed messages, and
  # `ignore: true` mutes it. A thread takes its parent channel's override unless
  # it has its own.
  class Routes
    PATH = Rails.root.join("config/agent_routes.yml")

    Override = Struct.new(:guild_id, :channel_id, :name, :default_soul, :ignore, keyword_init: true) do
      def ignore? = ignore == true
    end

    # Where the floor escalates to a person when no `floor.escalation_email` is set.
    DEFAULT_OPS_EMAIL = "alex@mcritchie.studio".freeze

    attr_reader :bot_user_id, :ops_channel_id, :ops_email

    def self.load(path = PATH)
      new(YAML.safe_load_file(path, aliases: false) || {})
    end

    def initialize(config)
      discord = (config["discord"] || {})
      @bot_user_id = discord["bot_user_id"].to_s.presence
      # Where the floor alert (AgentDispatcherAlertJob) posts. It is read for
      # inbound like any channel of its guild; it is not special here.
      @ops_channel_id = discord["ops_channel_id"].to_s.presence
      # Where the floor alert escalates by email (FloorAlert#escalate): an
      # incident open 15 minutes, or flapping.
      @ops_email = (config["floor"] || {})["escalation_email"].to_s.strip.presence || DEFAULT_OPS_EMAIL
      @guilds = (discord["guilds"] || {}).to_h { |id, guild| [ id.to_s, guild || {} ] }
      @overrides = build_overrides
      # The CTOs the web chat may route to (the `web:` block). A soul not
      # listed has no web chat.
      @web_souls = Array((config["web"] || {})["souls"]).map { |soul| soul.to_s.strip }.reject(&:empty?).uniq
      # The satellite apps that may address a soul over the hub's agent chat API
      # (Api::V1::AgentChatsController): `web: apps: <app slug>: [souls]`. A soul
      # an app names here still needs to be in `web: souls:`.
      @web_apps = ((config["web"] || {})["apps"] || {}).to_h do |app, souls|
        [ app.to_s.strip, Array(souls).map { |soul| soul.to_s.strip }.reject(&:empty?).uniq ]
      end
    end

    attr_reader :web_souls, :web_apps

    def web_soul?(soul) = @web_souls.include?(soul.to_s)

    # Whether satellite `app` may chat with `soul`: the app names the soul under
    # `web: apps:` AND the soul has a web chat (`web: souls:`).
    def web_app_soul?(app, soul) = web_soul?(soul) && Array(@web_apps[app.to_s]).include?(soul.to_s)

    # Every listed guild id, in config order.
    def guild_ids = @guilds.keys

    def guild?(guild_id) = @guilds.key?(guild_id.to_s)

    def guild_name(guild_id) = @guilds.dig(guild_id.to_s, "name").to_s.presence

    # Every per-channel override, in config order.
    def overrides = @overrides.values

    # The override that governs a channel: its own entry, else (for a thread or
    # forum post) its parent channel's. nil when neither has one.
    def override(guild_id, channel_id, parent_id: nil)
      guild_id = guild_id.to_s
      @overrides[[ guild_id, channel_id.to_s ]] || (parent_id.present? && @overrides[[ guild_id, parent_id.to_s ]]) || nil
    end

    def ignored?(guild_id, channel_id, parent_id: nil)
      override(guild_id, channel_id, parent_id: parent_id)&.ignore? || false
    end

    def default_soul(guild_id, channel_id, parent_id: nil)
      override(guild_id, channel_id, parent_id: parent_id)&.default_soul
    end

    # { "user" => { id => soul }, "role" => { id => soul } } for one guild.
    def mention_map(guild_id)
      souls = (@guilds.dig(guild_id.to_s, "souls") || {})
      souls.each_with_object({ "user" => {}, "role" => {} }) do |(soul, ids), map|
        ids ||= {}
        Array(ids["users"]).each { |id| map["user"][id.to_s] = soul.to_s }
        Array(ids["roles"]).each { |id| map["role"][id.to_s] = soul.to_s }
      end
    end

    # Every soul this config can route to: the guilds' souls, each override's
    # default_soul, and the web chat's CTOs.
    def souls
      (@guilds.values.flat_map { |g| (g["souls"] || {}).keys.map(&:to_s) } +
        overrides.map(&:default_soul).compact + @web_souls).uniq
    end

    # The process's routes, read once. Tests swap them with `current=` and `reset!`.
    class << self
      def current = @current ||= load

      attr_writer :current

      def reset! = @current = nil
    end

    private

    def build_overrides
      @guilds.each_with_object({}) do |(guild_id, guild), map|
        (guild["channels"] || {}).each do |channel_id, channel|
          channel ||= {}
          map[[ guild_id, channel_id.to_s ]] =
            Override.new(guild_id: guild_id, channel_id: channel_id.to_s, name: channel["name"].to_s.presence,
                         default_soul: channel["default_soul"].to_s.strip.presence, ignore: channel["ignore"] == true)
        end
      end
    end
  end
end
