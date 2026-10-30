require "test_helper"
require_relative "../../support/report_destination_fixtures"

# [integration] The standalone posters moved onto Media.home (config/agent_media.yml)
# post to the same Discord target as before: the floor alert and the change-build
# ops line to the old ops_channel_id as the shared bot, release notes and app
# requests through ReleaseNotes::DiscordClient to the same webhooks, and a report
# with no destination row stays not_configured unless its home names a channel
# (a row chosen in admin still wins). Discord is a recording transport.
class MediaHomePostersTest < ActiveSupport::TestCase
  include ReportDestinationFixtures

  OPS = "1479973077021495478".freeze # config/agent_media.yml discord.channels.ops

  class Recorder
    attr_reader :posts

    def initialize = @posts = []

    def call(method, url, _headers, body)
      @posts << [ method, url, JSON.parse(body) ]
      [ 200, JSON.generate("id" => "1#{@posts.size}") ]
    end
  end

  setup { Media::Config.reset! }
  teardown { Media::Config.reset! }

  def recording_bot(recorder) = AgentMessages::DiscordBot.new(token: "test-token", transport: recorder)

  test "[integration] Media::Discord#post: an id channel goes to the bot with the nonce; a webhook channel to DiscordClient" do
    recorder = Recorder.new
    home = Media.home(purpose: :floor_alert)
    Media.post(home, content: "hello", nonce: "n-1", bot: recording_bot(recorder))
    method, url, body = recorder.posts.sole
    assert_equal :post, method
    assert_match %r{/channels/#{OPS}/messages\z}, url
    assert_equal [ "hello", "n-1", true ], body.values_at("content", "nonce", "enforce_nonce")

    calls = []
    ReleaseNotes::DiscordClient.stub(:deliver, ->(**kwargs) { calls << kwargs }) do
      with_envs("DISCORD_RELEASE_NOTES_WEBHOOK_URL" => nil, "DISCORD_DEPLOY_WEBHOOK_URL" => "https://d.example/deploy") do
        Media.post(Media.home(purpose: :release_notes), content: "notes", embeds: [ { title: "t" } ])
      end
    end
    assert_equal [ { content: "notes", embeds: [ { title: "t" } ], webhook_url: "https://d.example/deploy" } ], calls

    assert_raises(ArgumentError) { Media.post(Media.home(purpose: :reports), content: "x") }
  end

  test "[integration] the floor alert, built with no arguments, posts to the old ops_channel_id" do
    AgentDispatcher.ping!({ "worker" => "d-1", "host" => "alex-mac", "souls" => [ "alex" ] }, now: 6.minutes.ago)
    recorder = Recorder.new
    AgentMessages::FloorAlert.new(bot: recording_bot(recorder), logger: Logger.new(nil)).call
    assert_operator recorder.posts.size, :>=, 1
    recorder.posts.each { |_method, url, _body| assert_match %r{/channels/#{OPS}/messages\z}, url }
    assert_match(/silent/i, recorder.posts.first[2]["content"])
  end

  test "[integration] the change-build ops line posts to the same ops channel" do
    recorder = Recorder.new
    task = Task.create!(title: "Change card", slug: "change-card-home", stage: "designed", priority: 1)
    task.update!(metadata: task.metadata.to_h.merge("devops" => task.devops.merge("repositories" => [ "turf-monster" ])))
    ChangeBuilds.post_to_ops!(task, bot: recording_bot(recorder))
    _method, url, body = recorder.posts.sole
    assert_match %r{/channels/#{OPS}/messages\z}, url
    assert_match(/change-card-home/, body["content"])
  end

  test "[integration] release notes from the conductor go to the release-notes webhook, else the deploy webhook" do
    calls = []
    formatter = Struct.new(:discord_payload, :message).new({ content: "Shipped" }, "Shipped")
    Release::Conductor.stub(:release_notes_formatter, formatter) do
      ReleaseNotes::DiscordClient.stub(:deliver, ->(**kwargs) { calls << kwargs }) do
        with_envs("DISCORD_RELEASE_NOTES_WEBHOOK_URL" => "https://d.example/notes", "DISCORD_DEPLOY_WEBHOOK_URL" => "https://d.example/deploy") do
          result = Release::Conductor.deliver_release_notes(release: nil, app: "hub", environment: "production", dry_run: false)
          assert result[:delivered]
        end
      end
    end
    assert_equal "https://d.example/notes", calls.sole[:webhook_url]
    assert_equal "Shipped", calls.sole[:content]
  end

  test "[integration] app requests post on the external lane's webhook through the app_requests home" do
    with_envs("DISCORD_EXTERNAL_WEBHOOK_URL" => "https://d.example/ext", "DISCORD_INTERNAL_WEBHOOK_URL" => "https://d.example/int") do
      assert_equal "https://d.example/ext", AppRequestDiscordJob.webhook_url
      assert_equal DiscordChannels.webhook_url(AppRequestDiscordJob::LANE), AppRequestDiscordJob.webhook_url
    end
  end

  test "[integration] a report with no row stays not_configured under the shipped home" do
    fake = fake_discord
    result = with_fake_discord(fake) { ReportDestinations.deliver("daily_app_report", content: "x", idempotency_key: "home:1") }
    assert_equal :not_configured, result.status
    assert_empty fake.posts
  end

  test "[integration] a report with no row posts to its home's channel; a row chosen in admin still wins" do
    home_channel = channel!
    other = channel!(external_id: NEWS, name: "news", kind: "announcement")
    Media::Config.current = Media::Config.new(
      "defaults" => { "medium" => "discord", "fallback" => "discord" },
      "discord" => { "enabled" => true, "channels" => { "reports" => { "id" => home_channel.external_id } } },
      "purposes" => { "reports" => { "channel" => "reports" } }
    )
    fake = fake_discord
    with_fake_discord(fake) do
      assert_equal :posted, ReportDestinations.deliver("daily_app_report", content: "x", idempotency_key: "home:2").status
      ReportDestination.create!(report_key: "daily_app_report", discord_channel: other, enabled: true)
      assert_equal :posted, ReportDestinations.deliver("daily_app_report", content: "y", idempotency_key: "home:3").status
      ReportDestination.for("daily_app_report").update!(enabled: false)
      assert_equal :disabled, ReportDestinations.deliver("daily_app_report", content: "z", idempotency_key: "home:4").status
    end
    assert_equal [ "/channels/#{REPORTS}/messages", "/channels/#{NEWS}/messages" ], fake.posts.map { |post| post[:path] }
    assert_equal "turf_monster", ReportDestinations.app_for("cto_report:turf_monster")
    assert_nil ReportDestinations.app_for("daily_app_report")
  end

  # Pin several ENV keys for the block (test_helper's with_env takes one).
  def with_envs(pairs, &block)
    return yield if pairs.empty?

    (key, value), *rest = pairs.to_a
    with_env(key, value) { with_envs(rest.to_h, &block) }
  end
end
