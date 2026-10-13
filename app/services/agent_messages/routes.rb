module AgentMessages
  # config/agent_routes.yml, read into a shape the poll and the router can ask:
  # which channels to poll, and which soul a mention names. Every id is a String.
  class Routes
    PATH = Rails.root.join("config/agent_routes.yml")

    Channel = Struct.new(:guild_id, :channel_id, :name, :default_soul, keyword_init: true)

    attr_reader :bot_user_id

    def self.load(path = PATH)
      new(YAML.safe_load_file(path, aliases: false) || {})
    end

    def initialize(config)
      discord = (config["discord"] || {})
      @bot_user_id = discord["bot_user_id"].to_s.presence
      @guilds = (discord["guilds"] || {}).to_h { |id, guild| [ id.to_s, guild || {} ] }
    end

    # Every allow-listed Discord channel, in config order.
    def channels
      @guilds.flat_map do |guild_id, guild|
        (guild["channels"] || {}).map do |channel_id, channel|
          channel ||= {}
          Channel.new(guild_id: guild_id, channel_id: channel_id.to_s, name: channel["name"].to_s.presence,
                      default_soul: channel["default_soul"].to_s.presence)
        end
      end
    end

    def channel(guild_id, channel_id)
      channels.find { |c| c.guild_id == guild_id.to_s && c.channel_id == channel_id.to_s }
    end

    def guild?(guild_id) = @guilds.key?(guild_id.to_s)

    # { "user" => { id => soul }, "role" => { id => soul } } for one guild.
    def mention_map(guild_id)
      souls = (@guilds.dig(guild_id.to_s, "souls") || {})
      souls.each_with_object({ "user" => {}, "role" => {} }) do |(soul, ids), map|
        ids ||= {}
        Array(ids["users"]).each { |id| map["user"][id.to_s] = soul.to_s }
        Array(ids["roles"]).each { |id| map["role"][id.to_s] = soul.to_s }
      end
    end

    # Every soul this config can route to.
    def souls
      (@guilds.values.flat_map { |g| (g["souls"] || {}).keys.map(&:to_s) } +
        channels.map(&:default_soul).compact).uniq
    end
  end
end
