# frozen_string_literal: true

module AgentSetups
  # Maps Discord's answers about a bot token to ready, or to the reason it is
  # not (SOP docs/agents/agents/steffon/sops/agent-onboarding.md). Plain Ruby,
  # no Rails: Steffon's `bin/agent-setup verify` (bin/lib/agent_setup_cli.rb)
  # uses it on the Mac with the token it just read, and AgentSetups::Command
  # uses it on the dyno with the token it just installed. Neither passes the
  # token here; only Discord's answers.
  #
  #   me_status, me          GET /users/@me: the status and the parsed body
  #   guilds_status, guilds  GET /users/@me/guilds: the bot's servers (optional)
  #   expected_id            the application id Alex McRitchie pasted; a bot's
  #                          user id is its application's id
  #   expected_name          the bot's name on the card
  #   guild_id               the server the invite adds it to (optional)
  #
  # Every reason is a sentence Alex McRitchie can act on, and none quotes the token.
  module DiscordVerdict
    Result = Struct.new(:ok, :reason, :bot_user_id, keyword_init: true) do
      def ok? = ok == true
    end

    module_function

    def call(me_status:, me:, expected_id:, expected_name:, guilds_status: nil, guilds: nil, guild_id: nil)
      me = me.is_a?(Hash) ? me : {}
      return fail_with(token_refused(me_status)) unless me_status.to_i == 200

      id = me["id"].to_s
      return fail_with("Discord answered without a user id; try again.") if id.empty?
      unless me["bot"] == true
        return fail_with("That token is not a bot's: paste the token from Bot → Reset Token.", id)
      end
      if expected_id.to_s.strip != "" && id != expected_id.to_s
        return fail_with("The token belongs to bot #{id}, not the application #{expected_id} on the card: reset the token in the right application, or fix the Application ID.", id)
      end

      name = me["username"].to_s
      if expected_name.to_s.strip != "" && !same_name?(name, expected_name)
        return fail_with("The bot is named #{name.inspect}, not #{expected_name.to_s.inspect}: rename it in the portal (Bot → Username).", id)
      end

      if guild_id.to_s.strip != ""
        return fail_with("Discord would not list the bot's servers (HTTP #{guilds_status}); try again.", id) unless guilds_status.to_i == 200
        unless Array(guilds).any? { |g| g.is_a?(Hash) && g["id"].to_s == guild_id.to_s }
          return fail_with("The bot is not in the server yet: use Invite (step 4).", id)
        end
      end

      Result.new(ok: true, reason: nil, bot_user_id: id)
    end

    # Discord may append a discriminator-free suffix or change case; a name
    # matches when it is the same ignoring case and surrounding space.
    def same_name?(actual, expected) = actual.to_s.strip.casecmp?(expected.to_s.strip)

    def token_refused(status)
      case status.to_i
      when 401 then "Discord refused the token (401): it was reset again or pasted wrong. Reset it, paste it into the 1Password item, and press Done."
      when 429 then "Discord rate-limited the check (429); try again in a minute."
      when 0 then "Discord did not answer; try again."
      else "Discord answered HTTP #{status} to the token; try again."
      end
    end

    def fail_with(reason, id = nil) = Result.new(ok: false, reason: reason, bot_user_id: id)
  end
end
