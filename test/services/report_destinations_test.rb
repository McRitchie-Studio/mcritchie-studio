require "test_helper"
require_relative "../support/report_destination_fixtures"

# [unit] ReportDestinations.deliver — THE CONTRACT (docs/agents/system/report-destinations.md):
# it resolves the chosen channel, posts once per idempotency_key with a derived
# nonce + enforce_nonce and no pings, records the delivery, and answers
# :posted / :not_configured / :disabled / :failed. An unknown key or a report over
# Discord's limits raises before anything is posted.
class ReportDestinationsTest < ActiveSupport::TestCase
  include ReportDestinationFixtures

  KEY = "daily_app_report".freeze

  def deliver(idempotency_key: "daily:2026-10-15", content: "Morning. All green.", embeds: [])
    ReportDestinations.deliver(KEY, content: content, embeds: embeds, idempotency_key: idempotency_key)
  end

  def configure!(enabled: true, **channel)
    ReportDestination.create!(report_key: KEY, discord_channel: channel!(**channel), enabled: enabled)
  end

  test "[unit] the registry seeds daily_app_report with its label and description" do
    registration = ReportDestinations.registration(KEY)
    assert_equal [ "Daily application report", "Morning CTO summary" ], [ registration.label, registration.description ]
    assert_not ReportDestinations.registered?("nope")
  end

  test "[unit] an unknown key, a blank idempotency_key and an empty report raise ArgumentError" do
    error = assert_raises(ArgumentError) { ReportDestinations.deliver("nope", content: "x", idempotency_key: "k") }
    assert_match(/unknown report key "nope"/, error.message)
    assert_raises(ArgumentError) { deliver(idempotency_key: " ") }
    assert_raises(ArgumentError) { deliver(content: "", embeds: []) }
    assert_equal 0, ReportDelivery.count
  end

  test "[unit] no destination is :not_configured, recorded, and posts nothing" do
    fake = fake_discord
    with_fake_discord(fake) do
      result = deliver
      assert_equal :not_configured, result.status
      assert_nil result.message_id
      assert_nil result.url
    end
    assert_empty fake.posts
    assert_equal "not_configured", ReportDelivery.sole.status
  end

  test "[unit] a disabled destination is :disabled; an archived or unpostable channel is :not_configured" do
    fake = fake_discord
    with_fake_discord(fake) do
      destination = configure!(enabled: false)
      assert_equal :disabled, deliver(idempotency_key: "a").status

      destination.update!(enabled: true)
      destination.discord_channel.update!(archived_at: Time.current)
      result = deliver(idempotency_key: "b")
      assert_equal :not_configured, result.status
      assert_match(/archived or not postable/, result.reason)
    end
    assert_empty fake.posts
  end

  test "[unit] it posts to the chosen channel with a derived nonce, enforce_nonce and no pings" do
    configure!
    fake = fake_discord
    result = with_fake_discord(fake) { deliver(embeds: [ { title: "Apps", description: "4 up" } ]) }

    assert_equal :posted, result.status
    assert_equal "920000000000000777", result.message_id
    assert_equal "https://discord.com/channels/#{GUILD}/#{REPORTS}/920000000000000777", result.url
    post = fake.posts.sole
    assert_equal "/channels/#{REPORTS}/messages", post[:path]
    assert_equal "Bot test-token", post[:auth]
    assert_equal "Morning. All green.", post[:body]["content"]
    assert_equal [ { "title" => "Apps", "description" => "4 up" } ], post[:body]["embeds"]
    assert_equal({ "parse" => [] }, post[:body]["allowed_mentions"])
    assert_equal true, post[:body]["enforce_nonce"]
    assert_equal ReportDestinations.nonce_for("daily:2026-10-15"), post[:body]["nonce"]
    assert_operator post[:body]["nonce"].length, :<=, 25

    delivery = ReportDelivery.sole
    assert_equal [ "posted", REPORTS, "920000000000000777" ], [ delivery.status, delivery.channel_external_id, delivery.message_external_id ]
  end

  test "[unit] the same idempotency_key never posts twice; a new key posts again" do
    configure!
    fake = fake_discord
    with_fake_discord(fake) do
      first = deliver
      second = deliver(content: "a different body, same key")
      assert_equal [ :posted, :posted ], [ first.status, second.status ]
      assert_equal first.message_id, second.message_id
      assert_equal 1, fake.posts.size

      deliver(idempotency_key: "daily:2026-10-16")
      assert_equal 2, fake.posts.size
    end
    assert_equal 2, ReportDelivery.count
  end

  test "[unit] a key used for another report raises rather than answering for it" do
    ReportDelivery.create!(report_key: "other_report", idempotency_key: "shared", status: "posted")
    assert_raises(ArgumentError) { deliver(idempotency_key: "shared") }
  end

  test "[unit] a Discord failure is :failed and recorded; the retry with the same key posts once" do
    configure!
    fake = fake_discord
    fake.overrides = { "/messages" => [ 500, { "message" => "boom" } ] }
    with_fake_discord(fake) do
      result = deliver
      assert_equal :failed, result.status
      assert_match(/HTTP 500/, result.reason)
      assert_equal "failed", ReportDelivery.sole.status
      log = ErrorLog.order(:id).last
      assert_equal [ ReportDelivery.sole, "report daily_app_report" ], [ log.target, log.target_name ]

      assert_raises(AgentMessages::DiscordBot::Error) do
        ReportDestinations.deliver!(KEY, content: "x", idempotency_key: "daily:2026-10-15")
      end
      assert_equal "failed", ReportDelivery.sole.reload.status, "the failure is committed before it is raised"

      fake.overrides = {}
      assert_equal :posted, deliver.status
    end
    assert_equal "posted", ReportDelivery.sole.reload.status
  end

  test "[unit] no bot token is :failed and posts nothing" do
    configure!
    with_env("DISCORD_AGENT_BOT_TOKEN", nil) do
      result = deliver
      assert_equal :failed, result.status
      assert_match(/DISCORD_AGENT_BOT_TOKEN is unset/, result.reason)
    end
  end

  test "[unit] content over 2000 UTF-16 units raises LimitExceeded before anything is recorded" do
    configure!
    assert_nothing_raised { ReportDestinations.check_limits!("a" * 2000, []) }
    error = assert_raises(ReportDestinations::LimitExceeded) { deliver(content: "🚀" * 1001) }
    assert_match(/content is 2002 characters; Discord's limit is 2000/, error.message)
    assert_kind_of ArgumentError, error
    assert_equal 0, ReportDelivery.count
  end

  test "[unit] more than 10 embeds, an over-long field or over 6000 embed characters raise LimitExceeded" do
    check = ->(embeds) { ReportDestinations.check_limits!("", embeds) }
    assert_nothing_raised { check.(Array.new(10) { { title: "t" } }) }
    assert_raises(ReportDestinations::LimitExceeded) { check.(Array.new(11) { { title: "t" } }) }
    assert_raises(ReportDestinations::LimitExceeded) { check.([ { title: "x" * 257 } ]) }
    assert_raises(ReportDestinations::LimitExceeded) { check.([ { "fields" => [ { "name" => "n", "value" => "v" * 1025 } ] } ]) }
    assert_raises(ReportDestinations::LimitExceeded) { check.([ { fields: Array.new(26) { { name: "n", value: "v" } } } ]) }
    two_big = Array.new(2) { { description: "d" * 3001 } }
    error = assert_raises(ReportDestinations::LimitExceeded) { check.(two_big) }
    assert_match(/total text is 6002/, error.message)
    assert_nothing_raised { check.(Array.new(2) { { description: "d" * 3000 } }) }
  end
end
