require "test_helper"

# [unit] Media.home (config/agent_media.yml): purpose → soul → app → defaults,
# the fallback walk past a medium that is not usable (logged once), Teams
# refusing everything, and the shipped file resolving every purpose to exactly
# the Discord destination its poster used before the file existed.
class MediaHomeTest < ActiveSupport::TestCase
  def config(overrides = {})
    Media::Config.new({
      "defaults" => { "medium" => "discord", "channel" => "internal", "fallback" => "discord" },
      "discord" => { "enabled" => true, "channels" => { "ops" => { "id" => "111" }, "internal" => { "webhook_env" => "HOME_TEST_INTERNAL" },
                                                        "avi-desk" => { "id" => "222" }, "turf" => { "id" => "333" } } },
      "slack" => { "enabled" => false, "fallback" => "discord", "channels" => {} },
      "teams" => { "enabled" => true, "fallback" => "discord", "channels" => { "ops" => { "id" => "teams-ops" } } },
      "purposes" => { "floor_alert" => { "medium" => "discord", "channel" => "ops" }, "reports" => { "channel" => nil } },
      "souls" => { "avi" => { "channel" => "avi-desk" } },
      "apps" => { "turf_monster" => { "channel" => "turf" } }
    }.deep_merge(overrides))
  end

  setup { Media.reset_fallback_notes! }

  test "[unit] resolution order: a purpose entry beats the soul, the soul beats the app, the app beats the defaults" do
    home = Media.home(purpose: :floor_alert, soul: "avi", app: "turf_monster", config: config)
    assert_equal [ "discord", "ops", "111", "purpose:floor_alert" ], [ home.medium, home.channel, home.channel_id, home.source ]

    home = Media.home(purpose: :release_notes, soul: "avi", app: "turf_monster", config: config)
    assert_equal [ "avi-desk", "soul:avi" ], [ home.channel, home.source ]

    home = Media.home(purpose: :release_notes, soul: "carl", app: "turf_monster", config: config)
    assert_equal [ "turf", "app:turf_monster" ], [ home.channel, home.source ]

    home = Media.home(purpose: :release_notes, soul: "carl", app: "cyvasse", config: config)
    assert_equal [ "discord", "internal", "defaults" ], [ home.medium, home.channel, home.source ]
    assert_equal [ "HOME_TEST_INTERNAL" ], home.webhook_envs
  end

  test "[unit] an entry with channel: null has no channel, so its poster posts nothing" do
    home = Media.home(purpose: :reports, app: "turf_monster", config: config)
    assert_equal "discord", home.medium, "the medium comes from the defaults"
    assert_nil home.channel
    refute home.channel?
  end

  test "[unit] a disabled medium falls back, keeping the channel name, and the walk is logged once" do
    cfg = config("purposes" => { "floor_alert" => { "medium" => "slack", "channel" => "ops" } })
    log = StringIO.new
    with_logger(Logger.new(log)) do
      3.times do
        home = Media.home(purpose: :floor_alert, config: cfg)
        assert_equal [ "discord", "ops", "111", [ "slack" ] ], [ home.medium, home.channel, home.channel_id, home.fell_from ]
      end
    end
    assert_equal 1, log.string.scan("slack is not usable").size, "one line per process, not one per minute"
    assert_includes log.string, "falling back to discord"
  end

  test "[unit] an unregistered medium and a medium with no block fall back too" do
    cfg = config("purposes" => { "floor_alert" => { "medium" => "pager", "channel" => "ops" } })
    assert_equal "discord", Media.home(purpose: :floor_alert, config: cfg).medium
  end

  test "[unit] Teams, even enabled in the file, cannot post, so the walk passes it by" do
    cfg = config("purposes" => { "floor_alert" => { "medium" => "teams", "channel" => "ops" } })
    home = Media.home(purpose: :floor_alert, config: cfg)
    assert_equal [ "discord", [ "teams" ] ], [ home.medium, home.fell_from ]
  end

  test "[unit] a walk with nowhere to land answers nil, and Media.post refuses a nil home with NoHome" do
    cfg = config("discord" => { "enabled" => false, "fallback" => "slack" })
    assert_nil Media.home(purpose: :floor_alert, config: cfg)
    error = assert_raises(Media::NoHome) { Media.post(nil, content: "x") }
    assert_kind_of Media::Error, error
  end

  test "[unit] Media::Teams is registered and disabled, and every method raises NotImplementedError" do
    teams = Media.adapter("teams")
    assert_instance_of Media::Teams, teams
    assert_equal "teams", teams.key
    refute teams.enabled?
    refute teams.configured?
    assert_empty teams.capabilities
    refute teams.supports?(:post)
    [ -> { teams.inbound_mode }, -> { teams.deliver_reply(Object.new) }, -> { teams.typing(Object.new, phase: "typing") },
      -> { teams.post(Object.new, content: "x") }, -> { teams.message_url(Object.new) }, -> { teams.setup_kit },
      -> { teams.actor } ].each { |call| assert_raises(NotImplementedError) { call.call } }
  end

  test "[unit] the shipped agent_media.yml resolves every purpose to the destination its poster used before" do
    shipped = Media::Config.load
    floor = Media.home(purpose: :floor_alert, config: shipped)
    assert_equal [ "discord", "1479973077021495478" ], [ floor.medium, floor.channel_id ], "the old discord.ops_channel_id"

    releases = Media.home(purpose: :release_notes, config: shipped)
    assert_equal %w[DISCORD_RELEASE_NOTES_WEBHOOK_URL DISCORD_DEPLOY_WEBHOOK_URL], releases.webhook_envs,
                 "ReleaseNotes::DiscordClient.webhook_url's order"
    with_envs("DISCORD_RELEASE_NOTES_WEBHOOK_URL" => nil, "DISCORD_DEPLOY_WEBHOOK_URL" => "https://d.example/deploy") do
      assert_equal ReleaseNotes::DiscordClient.webhook_url, releases.webhook_url
    end

    requests = Media.home(purpose: :app_requests, config: shipped)
    assert_equal [ DiscordChannels.lane(AppRequestDiscordJob::LANE)[:env] ], requests.webhook_envs
    assert_equal [ DiscordChannels.lane(:internal)[:env] ], Media.home(purpose: :nothing, config: shipped).webhook_envs

    refute Media.home(purpose: :reports, app: "turf_monster", config: shipped).channel?, "a report with no row stays not_configured"
    refute shipped.enabled?("slack")
    assert_equal %w[SLACK_BOT_TOKEN SLACK_SIGNING_SECRET], shipped.medium("slack").values_at("token_env", "signing_secret_env")
    refute shipped.enabled?("teams")
    %w[mcritchie_studio turf_monster cyvasse].each { |app| assert_equal "discord", Media.home(purpose: :x, app: app, config: shipped).medium }
  end

  test "[unit] the reply job's give-up event names the medium's actor, not a hard-coded discord-bot" do
    assert_equal "discord-bot", AgentMessageReplyJob.give_up_actor(AgentMessage.new(channel: "discord"))
    assert_equal "email", AgentMessageReplyJob.give_up_actor(AgentMessage.new(channel: "email"))
    assert_equal "web-chat", AgentMessageReplyJob.give_up_actor(AgentMessage.new(channel: "web"))
    assert_equal "teams-bot", AgentMessageReplyJob.give_up_actor(AgentMessage.new(channel: "teams"))
  end

  private

  def with_logger(logger)
    original = Rails.logger
    Rails.logger = logger
    yield
  ensure
    Rails.logger = original
  end

  # Pin several ENV keys for the block (test_helper's with_env takes one).
  def with_envs(pairs, &block)
    return yield if pairs.empty?

    (key, value), *rest = pairs.to_a
    with_env(key, value) { with_envs(rest.to_h, &block) }
  end
end
