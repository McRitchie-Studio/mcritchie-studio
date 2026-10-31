module AgentMessages
  # The `teams:` block of config/agent_routes.yml: which Entra tenant is read,
  # the bot's app id, Alex McRitchie's Entra object id, and (shared with Slack
  # through ChannelRoutes) which souls a Teams message is for and which souls may
  # answer in which channel (docs/agents/system/agent-message-loop.md, "Teams").
  # Pure. Channels are keyed by the channel's conversation id
  # (19:…@thread.tacv2, never with ;messageid=).
  class TeamsRoutes < ChannelRoutes
    BLOCK = "teams".freeze
    LABEL = "Teams".freeze
    TENANT_ENV = "TEAMS_TENANT_ID".freeze
    APP_ID_ENV = "TEAMS_BOT_APP_ID".freeze

    def initialize(config)
      config ||= {}
      super
      @tenant_id = config["tenant_id"].to_s.strip.presence
      @bot_app_id = config["bot_app_id"].to_s.strip.presence
      @owner_aad_object_id = config["owner_aad_object_id"].to_s.strip.presence
    end

    # The tenant read: TEAMS_TENANT_ID, else the block's tenant_id. With
    # neither, nothing is.
    def tenant_id = ENV[TENANT_ENV].to_s.strip.presence || @tenant_id

    # The bot's Microsoft App id (the JWT audience; the bot's own account is
    # "28:<app id>"): TEAMS_BOT_APP_ID, else the block's bot_app_id.
    def bot_app_id = ENV[APP_ID_ENV].to_s.strip.presence || @bot_app_id

    # Alex McRitchie's Entra object id (an activity's from.aadObjectId), linked
    # to the owner person (AgentPerson.seed_owner!). Empty until the tenant exists.
    def owner_aad_object_id = @owner_aad_object_id

    # The owner's id as the noise caps read it (Media::Limits#owner_user_id).
    def owner_user_id = owner_aad_object_id

    def tenant?(id) = tenant_id.present? && id.to_s.casecmp?(tenant_id)

    # The bot's own account id on Teams.
    def bot_account_id = bot_app_id && "28:#{bot_app_id}"

    # Whether `account_id` (a mention entity's mentioned.id, an activity's
    # recipient.id) is the bot.
    def bot?(account_id)
      id = account_id.to_s
      return false if id.empty?

      id == bot_account_id || (bot_app_id.present? && id == bot_app_id)
    end
  end
end
