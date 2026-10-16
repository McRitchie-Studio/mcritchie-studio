require "test_helper"
require_relative "../support/report_destination_fixtures"

# [unit] Which bot posts a report (docs/agents/system/report-destinations.md,
# "Which bot posts"): a `cto_report:<domain>` key posts as its CTO soul's own
# bot (config/cto_reports.yml) when DISCORD_BOT_TOKEN_<SOUL> is set, else as
# the shared bot; a 401/403 from the soul's bot is an ErrorLog and one shared
# fallback, never a dropped or doubled report; every other key is shared only.
class ReportDestinationsBotTest < ActiveSupport::TestCase
  include ReportDestinationFixtures

  TURF_KEY = "cto_report:turf_monster".freeze
  TURF_TOKEN = "turf-soul-secret".freeze
  TURF_ENV = "DISCORD_BOT_TOKEN_TURF_MONSTER".freeze
  SOUL_ENVS = %w[DISCORD_BOT_TOKEN_AVI DISCORD_BOT_TOKEN_TURF_MONSTER DISCORD_BOT_TOKEN_TYRION].freeze

  def configure!(key)
    ReportDestination.create!(report_key: key, discord_channel: DiscordChannel.find_by(external_id: REPORTS) || channel!, enabled: true)
  end

  def deliver(key = TURF_KEY, idempotency_key: "#{TURF_KEY}:2026-10-16")
    ReportDestinations.deliver(key, content: "**Turf Monster · CTO report**\n— Turf", embeds: [ { title: "Health" } ],
                                    idempotency_key: idempotency_key)
  end

  # Every soul token set (or blank), so a test sees exactly the bots it names.
  def with_soul_tokens(tokens, &block)
    SOUL_ENVS.reverse.inject(block) { |inner, env| -> { with_env(env, tokens[env]) { inner.call } } }.call
  end

  # The fake, but a POST by `refuse` (an Authorization header) answers `status`.
  def refusing(fake, refuse, status)
    lambda do |method, url, headers, body|
      next fake.call(method, url, headers, body) unless method == :post && headers["Authorization"] == refuse

      fake.requests << { method: method, path: url.delete_prefix(AgentMessages::DiscordBot::API), auth: refuse, body: JSON.parse(body) }
      [ status, JSON.generate("message" => "Missing Permissions", "code" => 50013) ]
    end
  end

  test "[unit] the soul comes from config/cto_reports.yml per report key; other keys have none" do
    assert_equal "avi", ReportDestinations.soul_for("cto_report:mcritchie_studio")
    assert_equal "turf_monster", ReportDestinations.soul_for("cto_report:turf_monster")
    assert_equal "tyrion", ReportDestinations.soul_for("cto_report:cyvasse")
    assert_nil ReportDestinations.soul_for("daily_app_report")
    assert_nil ReportDestinations.soul_for("cto_report:unknown_app")
    assert_nil CtoReport.soul_for("turf_monster"), "a bare domain is not a report key"
    assert_equal "pinned", CtoReport.soul_for("cto_report:x", config: { "x" => { "soul" => "pinned" } })
  end

  test "[unit] bot_choice: soul bot with its token, shared without, non-CTO keys always shared" do
    with_soul_tokens(TURF_ENV => TURF_TOKEN, "DISCORD_BOT_TOKEN_AVI" => "avi-secret", "DISCORD_BOT_TOKEN_TYRION" => " ") do
      assert_equal "soul_bot", ReportDestinations.bot_choice("cto_report:turf_monster").via
      assert_equal "soul_bot", ReportDestinations.bot_choice("cto_report:mcritchie_studio").via
      cyvasse = ReportDestinations.bot_choice("cto_report:cyvasse")
      assert_equal [ "tyrion", "DISCORD_BOT_TOKEN_TYRION", "shared_bot" ], [ cyvasse.soul, cyvasse.token_env, cyvasse.via ],
                   "a blank token is no token"
      daily = ReportDestinations.bot_choice("daily_app_report")
      assert_equal [ nil, "shared_bot" ], [ daily.soul, daily.via ]
    end
  end

  test "[unit] a CTO report posts as its soul's bot when the token is set, and records it" do
    configure!(TURF_KEY)
    fake = fake_discord
    result = with_fake_discord(fake) { with_soul_tokens(TURF_ENV => TURF_TOKEN) { deliver } }

    assert_equal :posted, result.status
    assert_equal [ "Bot #{TURF_TOKEN}" ], fake.posts.map { |p| p[:auth] }
    assert_equal "**Turf Monster · CTO report**\n— Turf", fake.posts.sole[:body]["content"], "the content is unchanged"
    assert_equal [ "posted", "soul_bot", nil ], ReportDelivery.sole.slice(:status, :posted_via, :soul_bot_refused_at).values
  end

  test "[unit] a CTO report without its soul token posts through the shared bot exactly as before" do
    configure!(TURF_KEY)
    fake = fake_discord
    with_fake_discord(fake) { with_soul_tokens(TURF_ENV => "") { assert_equal :posted, deliver.status } }

    assert_equal [ "Bot test-token" ], fake.posts.map { |p| p[:auth] }
    assert_equal "shared_bot", ReportDelivery.sole.posted_via
  end

  test "[unit] daily_app_report posts through the shared bot even with every soul token set" do
    configure!("daily_app_report")
    fake = fake_discord
    with_fake_discord(fake) do
      with_soul_tokens(SOUL_ENVS.index_with { |e| "#{e.downcase}-secret" }) do
        deliver("daily_app_report", idempotency_key: "daily_app_report:2026-10-16")
      end
    end
    assert_equal [ "Bot test-token" ], fake.posts.map { |p| p[:auth] }
    assert_equal "shared_bot", ReportDelivery.sole.posted_via
  end

  test "[unit] 401/403 from the soul's bot: ErrorLog, one shared fallback, posted once, no token in the log" do
    [ 401, 403 ].each_with_index do |status, i|
      ReportDestination.delete_all
      configure!(TURF_KEY)
      fake = fake_discord
      key = "#{TURF_KEY}:refused-#{i}"
      result = with_fake_discord(fake) do
        AgentMessages::DiscordBot.transport = refusing(fake, "Bot #{TURF_TOKEN}", status)
        with_soul_tokens(TURF_ENV => TURF_TOKEN) { deliver(idempotency_key: key) }
      end

      assert_equal :posted, result.status, "the report is never dropped"
      assert_equal [ "Bot #{TURF_TOKEN}", "Bot test-token" ], fake.posts.map { |p| p[:auth] }
      delivery = ReportDelivery.find_by!(idempotency_key: key)
      assert_equal "shared_bot", delivery.posted_via
      assert delivery.soul_bot_refused_at
      assert_nil delivery.error

      log = ErrorLog.where(target: delivery).sole
      assert_equal "#{TURF_ENV} report #{TURF_KEY}", log.target_name
      assert_match(/HTTP #{status}/, log.message)
      ErrorLog.where(target: delivery).pluck(:message, :target_name).flatten.compact.each do |text|
        assert_not_includes text, TURF_TOKEN
      end
    end
  end

  test "[unit] after a refusal, a retry of the same key never reaches the soul's bot again" do
    configure!(TURF_KEY)
    fake = fake_discord
    with_fake_discord(fake) do
      # The soul's bot is refused, then the shared post fails: the receipt is failed.
      refused = refusing(fake, "Bot #{TURF_TOKEN}", 403)
      AgentMessages::DiscordBot.transport = lambda do |method, url, headers, body|
        if method == :post && headers["Authorization"] == "Bot test-token"
          fake.requests << { method: method, auth: headers["Authorization"] }
          next [ 500, JSON.generate("message" => "boom") ]
        end

        refused.call(method, url, headers, body)
      end
      with_soul_tokens(TURF_ENV => TURF_TOKEN) do
        assert_equal :failed, deliver.status
        assert ReportDelivery.sole.soul_bot_refused_at

        # Discord now lets the soul's bot in; the retry still goes to the shared bot.
        AgentMessages::DiscordBot.transport = fake.to_proc
        assert_equal :posted, deliver.status
      end
    end
    assert_equal [ "Bot #{TURF_TOKEN}", "Bot test-token", "Bot test-token" ], fake.posts.map { |p| p[:auth] }
    assert_equal "shared_bot", ReportDelivery.sole.posted_via
  end

  test "[unit] a soul refused with no shared token fails, saying why, and is retried later" do
    configure!(TURF_KEY)
    fake = fake_discord
    with_fake_discord(fake) do
      AgentMessages::DiscordBot.transport = refusing(fake, "Bot #{TURF_TOKEN}", 403)
      with_env("DISCORD_AGENT_BOT_TOKEN", nil) do
        with_soul_tokens(TURF_ENV => TURF_TOKEN) do
          result = deliver
          assert_equal :failed, result.status
          assert_match(/the CTO's own bot was refused and DISCORD_AGENT_BOT_TOKEN is unset/, result.reason)
          assert_not_includes result.reason, TURF_TOKEN
        end
      end
    end
  end

  test "[unit] a CTO report posts through its soul bot even when the shared token is unset" do
    configure!(TURF_KEY)
    fake = fake_discord
    with_fake_discord(fake) do
      with_env("DISCORD_AGENT_BOT_TOKEN", nil) do
        with_soul_tokens(TURF_ENV => TURF_TOKEN) { assert_equal :posted, deliver.status }
      end
    end
    assert_equal [ "Bot #{TURF_TOKEN}" ], fake.posts.map { |p| p[:auth] }
  end
end
