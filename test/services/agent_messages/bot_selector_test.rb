require "test_helper"

# [unit] AgentMessages::BotSelector — the one place a soul's own Discord bot is
# picked over the shared bot, for chat replies and CTO reports alike: soul bot
# when DISCORD_BOT_TOKEN_<SOUL> is set, shared bot otherwise, one fallback on a
# 401/403, no fallback on any other error, and no token in anything it hands back.
class AgentMessages::BotSelectorTest < ActiveSupport::TestCase
  SOUL_TOKEN = "soul-secret-token-turf".freeze
  SHARED_TOKEN = "shared-secret-token".freeze

  # The bot's one network seam: answers by the Authorization header, records each call.
  def with_transport(answers, calls)
    previous = AgentMessages::DiscordBot.transport
    AgentMessages::DiscordBot.transport = lambda do |_method, _url, headers, _body|
      calls << headers["Authorization"]
      status = answers.fetch(headers["Authorization"], 200)
      raise AgentMessages::DiscordBot::Error, "Discord unreachable: Net::ReadTimeout" if status == :timeout

      [ status, JSON.generate(status == 200 ? { "id" => "1" } : { "message" => "Missing Access #{SOUL_TOKEN}" }) ]
    end
    yield
  ensure
    AgentMessages::DiscordBot.transport = previous
  end

  def with_tokens(soul: SOUL_TOKEN, shared: SHARED_TOKEN, &block)
    with_env("DISCORD_BOT_TOKEN_TURF_MONSTER", soul) { with_env("DISCORD_AGENT_BOT_TOKEN", shared, &block) }
  end

  def post_report(**opts, &on_refused)
    AgentMessages::BotSelector.post("turf_monster", on_refused: on_refused, **opts) do |bot, via|
      [ bot.post_report("42", content: "hi", embeds: [], nonce: "n"), via ]
    end
  end

  test "[unit] choice names the soul's ENV var and whether it is set, never the token" do
    with_tokens do
      choice = AgentMessages::BotSelector.choice("turf_monster")
      assert_equal [ "turf_monster", "DISCORD_BOT_TOKEN_TURF_MONSTER", true, "soul_bot" ],
                   [ choice.soul, choice.token_env, choice.soul_token_set, choice.via ]
      assert_not_includes choice.to_h.values.map(&:to_s).join(" "), SOUL_TOKEN
    end
    with_tokens(soul: "  ") do
      assert_equal "shared_bot", AgentMessages::BotSelector.choice("turf_monster").via, "a blank token is no token"
    end
    none = AgentMessages::BotSelector.choice(nil)
    assert_equal [ nil, nil, "shared_bot" ], [ none.soul, none.token_env, none.via ]
  end

  test "[unit] the soul's own bot posts when its token is set" do
    calls = []
    with_tokens { with_transport({}, calls) { assert_equal "soul_bot", post_report.last } }
    assert_equal [ "Bot #{SOUL_TOKEN}" ], calls
  end

  test "[unit] a blank or absent soul token, or no soul, posts through the shared bot" do
    [ nil, "", "   " ].each do |blank|
      calls = []
      with_tokens(soul: blank) { with_transport({}, calls) { assert_equal "shared_bot", post_report.last } }
      assert_equal [ "Bot #{SHARED_TOKEN}" ], calls
    end
    calls = []
    with_tokens do
      with_transport({}, calls) do
        _, via = AgentMessages::BotSelector.post(nil) { |bot, v| bot.post_report("42", content: "x", embeds: [], nonce: "n") && v }
        assert_equal "shared_bot", via
      end
    end
    assert_equal [ "Bot #{SHARED_TOKEN}" ], calls
  end

  test "[unit] a 401 or 403 from the soul's bot calls on_refused and falls back to the shared bot once" do
    [ 401, 403 ].each do |status|
      calls = []
      refusals = []
      with_tokens do
        with_transport({ "Bot #{SOUL_TOKEN}" => status }, calls) do
          (_, via), chosen = post_report { |error, env| refusals << [ error, env ] }
          assert_equal [ "shared_bot", "shared_bot" ], [ via, chosen ]
        end
      end
      assert_equal [ "Bot #{SOUL_TOKEN}", "Bot #{SHARED_TOKEN}" ], calls, "one soul try, one shared post"
      error, env = refusals.sole
      assert_kind_of AgentMessages::DiscordBot::Unauthorized, error
      assert_equal "DISCORD_BOT_TOKEN_TURF_MONSTER", env
      assert_match(/HTTP #{status}/, error.message)
      assert_not_includes error.message, SOUL_TOKEN, "the token never rides an error"
      assert_includes error.message, "[REDACTED]"
    end
  end

  test "[unit] any other soul-bot error raises, never falls back to a second bot" do
    calls = []
    with_tokens do
      with_transport({ "Bot #{SOUL_TOKEN}" => :timeout }, calls) do
        assert_raises(AgentMessages::DiscordBot::Error) { post_report { flunk "a timeout is not a refusal" } }
      end
    end
    assert_equal [ "Bot #{SOUL_TOKEN}" ], calls
  end

  test "[unit] skip_soul goes straight to the shared bot; with no shared token the answer is nil" do
    calls = []
    with_tokens { with_transport({}, calls) { assert_equal "shared_bot", post_report(skip_soul: true).last } }
    assert_equal [ "Bot #{SHARED_TOKEN}" ], calls

    calls = []
    with_tokens(shared: nil) do
      with_transport({ "Bot #{SOUL_TOKEN}" => 403 }, calls) { assert_nil post_report { nil } }
    end
    assert_equal [ "Bot #{SOUL_TOKEN}" ], calls
  end
end
