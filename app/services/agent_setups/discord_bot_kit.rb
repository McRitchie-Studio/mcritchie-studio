module AgentSetups
  # The Discord bot kit: the five steps of a soul's own Discord application,
  # every one a button or a copy field (epic agent-onboarding; SOP
  # docs/agents/agents/steffon/sops/agent-onboarding.md):
  #
  #   create_app   open the Developer Portal; copy the exact name; download the
  #                avatar; paste the Application ID back (public, not a secret)
  #   reset_token  Bot → Message Content Intent on → Reset Token, copy it once
  #   paste_token  open Steffon's EMPTY 1Password item and paste it into bot-token
  #   invite       add the bot to the server with its seat's permissions
  #   done         Done: AgentSetupCheckJob, then Steffon's verify
  #
  # The token never passes through the hub: the card only links to where it is
  # made and where it is kept. Details (all public): bot_name, application_id,
  # guild_id, guild_name, permissions, secret_env, install_app, op_vault,
  # op_item, op_field, and op_account_id/op_vault_id/op_item_id/op_host, which
  # build the item's deep link.
  module DiscordBotKit
    CONFIG_PATH = Rails.root.join("config/agent_setups.yml")
    STEP_KEYS = %w[create_app reset_token paste_token invite done].freeze
    PORTAL_URL = "https://discord.com/developers/applications".freeze
    AUTHORIZE_URL = "https://discord.com/oauth2/authorize".freeze
    # A Discord snowflake: an application or user id.
    SNOWFLAKE = /\A\d{17,20}\z/
    # 1Password's ids are 26 lowercase base32 characters; the host is the
    # account's sign-in address.
    OP_ID = /\A[a-z0-9]{26}\z/
    OP_HOST = /\A[a-z0-9-]+(\.[a-z0-9-]+)*\.1password\.(com|ca|eu)\z/

    module_function

    def config = @config ||= YAML.safe_load_file(CONFIG_PATH).fetch("discord_bot")
    def reset_config! = @config = nil
    def step_keys = STEP_KEYS

    # The permission set a soul's seat needs: named in `seats`, else `cto` for a
    # CTO (config/cto_reports.yml), else `reply`.
    def permission_set_for(soul)
      config.fetch("seats", {})[soul.to_s] ||
        (CtoReport.config.values.any? { |entry| entry.to_h["soul"] == soul.to_s } ? "cto" : "reply")
    end

    def permissions_for(set)
      DiscordPermissions.bits(config.fetch("permission_sets").fetch(set.to_s) { raise ArgumentError, "unknown permission set #{set.inspect}" })
    end

    def default_details(soul)
      agent = Agent.find_by(slug: soul)
      set = permission_set_for(soul)
      {
        "bot_name" => agent&.name || soul.to_s.titleize,
        "guild_id" => config["guild_id"].to_s,
        "guild_name" => config["guild_name"],
        "permission_set" => set,
        "permissions" => permissions_for(set).to_s,
        "secret_env" => AgentMessages::DiscordBot.soul_token_env(soul),
        "install_app" => config["install_app"],
        "op_vault" => config["op_vault"],
        "op_item" => "agents.discord.#{soul}",
        "op_field" => config["op_field"]
      }
    end

    def application_id(setup)
      id = setup.detail(:application_id).to_s
      id.match?(SNOWFLAKE) ? id : nil
    end

    def submit_blocker(setup)
      return "Paste the Application ID from the portal first (step 1)." unless application_id(setup)

      nil
    end

    # The OAuth2 invite: the bot (and its slash commands) with the seat's
    # permissions, the server pre-selected. Nil until the application id is in.
    def invite_url(setup)
      app_id = application_id(setup) or return nil
      query = { client_id: app_id, scope: config.fetch("scopes").join(" "), permissions: setup.detail(:permissions),
                guild_id: setup.detail(:guild_id), disable_guild_select: ("true" if setup.detail(:guild_id)) }.compact
      "#{AUTHORIZE_URL}?#{URI.encode_www_form(query).gsub('+', '%20')}"
    end

    # The 1Password deep link to Steffon's pre-created item, or nil when any id
    # is missing or malformed. It opens the item in the app; nothing is read.
    def op_link(setup)
      ids = %w[op_account_id op_vault_id op_item_id].map { |k| setup.detail(k).to_s }
      host = setup.detail(:op_host).to_s
      return nil unless ids.all? { |id| id.match?(OP_ID) } && host.match?(OP_HOST)

      "https://start.1password.com/open/i?#{URI.encode_www_form(a: ids[0], v: ids[1], i: ids[2], h: host)}"
    end

    def avatar_path(setup) = setup.agent&.avatar.presence

    # The hub's half of the check, after Done. It holds no token of the new bot
    # and no 1Password right, so it checks only what it can: the application id
    # is a snowflake, and, through the agents' shared bot, that the new bot is a
    # member of the server. Answers [:verifying, note] or [:needs_attention, reason].
    def hub_check(setup, discord: nil)
      app_id = application_id(setup) or return [ :needs_attention, "The Application ID is missing or not a Discord id: paste it again in step 1." ]
      guild = setup.detail(:guild_id)
      waiting = "Waiting for Steffon to verify the token and install it as #{setup.detail(:secret_env)}."
      return [ :verifying, waiting ] if guild.blank?

      discord ||= AgentMessages::DiscordBot.new if AgentMessages::DiscordBot.configured?
      return [ :verifying, "The hub could not check the server (no shared bot token here). #{waiting}" ] unless discord

      begin
        discord.guild_member(guild, app_id)
        [ :verifying, "The bot is in #{setup.detail(:guild_name) || 'the server'}. #{waiting}" ]
      rescue AgentMessages::DiscordBot::Unauthorized
        [ :verifying, "The shared bot could not read the server's members, so Steffon's verify checks it. #{waiting}" ]
      rescue AgentMessages::DiscordBot::Error => e
        raise unless e.message.include?("HTTP 404")

        [ :needs_attention, "The bot is not in #{setup.detail(:guild_name) || 'the server'} yet: use Invite (step 4), then Done again." ]
      end
    end
  end
end
