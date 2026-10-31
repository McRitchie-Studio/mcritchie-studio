module AgentMessages
  # The `slack:` block of config/agent_routes.yml: which workspace is read, the
  # app's own bot user, the owner's Slack user, which souls a Slack message is
  # for (one or several: #addressed, #everyone?), and which souls may answer in
  # which channel (CLEARANCE, #cleared?)
  # (docs/agents/system/agent-message-loop.md, "Slack"). Pure: it reads
  # text and ids and touches nothing. The THREAD rule needs the database, so
  # AgentMessages::SlackIngest applies it between #named and #mention_soul.
  #
  # The addressing, clearance, recognized names, core_souls and channel
  # defaults are medium-neutral and live in ChannelRoutes, shared with Teams
  # (TeamsRoutes); this class adds what only Slack has: the team, the bot user,
  # <@U…> mentions and the <!channel> broadcast.
  class SlackRoutes < ChannelRoutes
    BLOCK = "slack".freeze
    LABEL = "Slack".freeze

    attr_reader :team_id, :bot_user_id, :owner_user_id

    def initialize(config)
      config ||= {}
      super
      @team_id = config["team_id"].to_s.strip.presence
      @bot_user_id = config["bot_user_id"].to_s.strip.presence
      @owner_user_id = config["owner_user_id"].to_s.strip.presence
    end

    # A workspace other than ours is never read. With no team_id configured,
    # nothing is.
    def team?(team_id) = @team_id.present? && team_id.to_s == @team_id

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

    # ChannelRoutes#everyone? plus Slack's own <!everyone>, <!channel>, <!here>.
    def everyone?(text) = opening_line(text).match?(BROADCAST) || super

    private

    BROADCAST = /\A<!(?:everyone|channel|here)(?:\|[^>]*)?>/
  end
end
