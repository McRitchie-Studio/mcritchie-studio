module AgentMessages
  # Which Discord bot speaks for a soul, and the one fallback when it cannot.
  # Shared by the chat replies (AgentMessageReplyJob) and the per-app CTO
  # reports (ReportDestinations), so both pick a bot the same way
  # (docs/agents/system/agent-message-loop.md, docs/agents/system/report-destinations.md).
  #
  #   SOUL BOT    the soul's own Discord app, when DISCORD_BOT_TOKEN_<SOUL> is set
  #   SHARED BOT  DISCORD_AGENT_BOT_TOKEN, for everyone else and as the fallback
  #
  #   posted, via = BotSelector.post("turf_monster", on_refused: ->(error, env) { … }) do |bot, via|
  #     bot.post_report(…)
  #   end
  #
  # The soul's bot is tried first. A 401/403 from it (a bad token, a bot not in
  # the guild, a missing channel permission) calls `on_refused` and falls back
  # to the shared bot, once, in the same call; Discord refused the post, so
  # nothing was posted twice. Any other error (a timeout, a 5xx, a rate limit)
  # raises, so the caller's retry tries the SAME bot again with the same nonce
  # and Discord folds a repeat into the message it already made. `skip_soul`
  # goes straight to the shared bot: a caller that remembers an earlier refusal
  # passes it, so a retry never reaches the soul's bot after a fallback.
  #
  # Returns [the block's value, via], or nil when no bot has a token. A token
  # never leaves this class or DiscordBot: `Choice` carries only the ENV name
  # and whether it is set.
  module BotSelector
    SOUL = "soul_bot".freeze
    SHARED = "shared_bot".freeze

    # What a soul would post as, with no token in it.
    #   soul            the soul slug, or nil (no soul: always the shared bot)
    #   token_env       DISCORD_BOT_TOKEN_<SOUL>, or nil
    #   soul_token_set  whether that var holds a token
    Choice = Struct.new(:soul, :token_env, :soul_token_set, keyword_init: true) do
      def via = soul_token_set ? SOUL : SHARED
      def soul_bot? = via == SOUL
    end

    module_function

    def choice(soul)
      soul = soul.to_s.presence
      return Choice.new(soul: nil, token_env: nil, soul_token_set: false) if soul.nil?

      Choice.new(soul: soul, token_env: DiscordBot.soul_token_env(soul), soul_token_set: !DiscordBot.soul_token(soul).nil?)
    end

    def post(soul, skip_soul: false, on_refused: nil)
      token = skip_soul ? nil : DiscordBot.soul_token(soul)
      if token
        begin
          return [ yield(DiscordBot.new(token: token), SOUL), SOUL ]
        rescue DiscordBot::Unauthorized => e
          on_refused&.call(e, DiscordBot.soul_token_env(soul))
        end
      end
      return nil unless DiscordBot.configured?

      [ yield(DiscordBot.new, SHARED), SHARED ]
    end
  end
end
