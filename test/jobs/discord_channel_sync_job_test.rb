require "test_helper"
require_relative "../support/report_destination_fixtures"

# [unit] DiscordChannelSyncJob — inert with one log line and no request when the
# bot token is unset; otherwise it syncs, and it is scheduled every 15 minutes.
class DiscordChannelSyncJobTest < ActiveJob::TestCase
  include ReportDestinationFixtures

  setup { DiscordChannelSyncJob.announced_idle = false }
  teardown { DiscordChannelSyncJob.announced_idle = false }

  test "[unit] no token: nothing is read and the idle line is logged once" do
    fake = fake_discord
    previous = AgentMessages::DiscordBot.transport
    AgentMessages::DiscordBot.transport = fake.to_proc
    lines = []
    logger = ActiveSupport::Logger.new(StringIO.new)
    logger.define_singleton_method(:info) { |msg = nil, &blk| lines << (msg || blk&.call) }
    with_env("DISCORD_AGENT_BOT_TOKEN", nil) do
      Rails.stub(:logger, logger) do
        assert_nil DiscordChannelSyncJob.perform_now
        assert_nil DiscordChannelSyncJob.perform_now
      end
    end
    assert_empty fake.requests
    assert_equal 1, lines.grep(/sync idle: DISCORD_AGENT_BOT_TOKEN is unset/).size
  ensure
    AgentMessages::DiscordBot.transport = previous
  end

  test "[unit] with a token it syncs the configured guild" do
    fake = fake_discord
    summary = with_fake_discord(fake) { DiscordChannelSyncJob.perform_now }
    assert summary.ok?
    assert fake.requests.any? { |r| r[:path] == "/guilds/1332466565203103744/channels" }
  end

  test "[unit] a refused guild read is written to ErrorLog" do
    fake = fake_discord
    fake.overrides = { "/channels" => [ 403, { "message" => "Missing Access" } ] }
    assert_difference -> { ErrorLog.count }, 1 do
      with_fake_discord(fake) { DiscordChannelSyncJob.perform_now }
    end
    assert_match(/Discord channel sync: guild 1332466565203103744: .*HTTP 403/, ErrorLog.order(:id).last.message)
  end

  test "[unit] a dead token (401) writes one ErrorLog row per outage, not one per run" do
    fake = fake_discord
    fake.overrides = { "/channels" => [ 401, { "message" => "401: Unauthorized" } ] }
    assert_difference -> { ErrorLog.count }, 1 do
      2.times { |i| travel(i.minutes) { with_fake_discord(fake) { DiscordChannelSyncJob.perform_now } } }
    end
    fake.overrides = {}
    travel(5.minutes) { with_fake_discord(fake) { DiscordChannelSyncJob.perform_now } }
    fake.overrides = { "/channels" => [ 401, { "message" => "401: Unauthorized" } ] }
    assert_difference -> { ErrorLog.count }, 1 do
      travel(10.minutes) { with_fake_discord(fake) { DiscordChannelSyncJob.perform_now } }
    end
  end

  test "[unit] it is scheduled every 15 minutes in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "discord_channel_sync")
    assert_equal [ "DiscordChannelSyncJob", "every 15 minutes" ], [ entry["class"], entry["schedule"] ]
  end
end
