module AgentMessages
  # Decides which soul an inbound Discord message is for. Pure: it reads the
  # message's guild, channel, text and mention lists against AgentMessages::Routes
  # and touches nothing.
  #
  # Order (config/agent_routes.yml says the same): a mentioned soul USER, then a
  # mentioned soul ROLE, then the channel's default soul, else unrouted. Among
  # several mentioned souls the one written first in the text wins, because that
  # is who the author addressed; the others are named in the result's detail.
  class Router
    Result = Struct.new(:soul, :routed_by, :detail, keyword_init: true) do
      def routed? = soul.present?
    end

    # <@123> and <@!123> are user mentions, <@&123> a role mention.
    MENTION = /<@(?<kind>[!&]?)(?<id>\d+)>/

    def initialize(routes)
      @routes = routes
    end

    def route(guild_id:, channel_id:, content:, mention_users: [], mention_roles: [])
      map = @routes.mention_map(guild_id)
      hits = mentions_in_text(content.to_s, map)
      hits += mentions_in_lists(map, mention_users, mention_roles) if hits.empty?
      hits = hits.uniq { |hit| hit[:soul] }

      if hits.any?
        first = hits.first
        detail = { "matched" => "#{first[:kind]}:#{first[:id]}" }
        detail["also_mentioned"] = hits.drop(1).map { |hit| hit[:soul] } if hits.size > 1
        return Result.new(soul: first[:soul], routed_by: first[:kind], detail: detail)
      end

      default = @routes.channel(guild_id, channel_id)&.default_soul
      return Result.new(soul: default, routed_by: "default", detail: { "matched" => "channel default" }) if default

      Result.new(soul: nil, routed_by: "none", detail: { "reason" => "no routed soul mentioned and no channel default" })
    end

    private

    def mentions_in_text(content, map)
      content.to_enum(:scan, MENTION).filter_map do
        match = Regexp.last_match
        kind = match[:kind] == "&" ? "role" : "user"
        soul = map[kind][match[:id]]
        soul && { soul: soul, kind: kind, id: match[:id] }
      end
    end

    # A mention Discord reports without one in the text (a reply that pings its
    # author, say): users first, then roles, as the precedence above.
    def mentions_in_lists(map, users, roles)
      Array(users).filter_map { |id| (soul = map["user"][id.to_s]) && { soul: soul, kind: "user", id: id.to_s } } +
        Array(roles).filter_map { |id| (soul = map["role"][id.to_s]) && { soul: soul, kind: "role", id: id.to_s } }
    end
  end
end
