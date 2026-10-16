require "test_helper"
require_relative "../support/report_destination_fixtures"

# [unit] ReportDeliveryJob — the async form of deliver: a Discord failure is
# retried (polynomially, same idempotency_key) and the report posts once.
class ReportDeliveryJobTest < ActiveJob::TestCase
  include ReportDestinationFixtures

  test "[unit] a failed post is retried with the same key and posts once" do
    ReportDestination.create!(report_key: "daily_app_report", discord_channel: channel!)
    fake = fake_discord
    fake.overrides = { "/messages" => [ 502, { "message" => "bad gateway" } ] }

    with_fake_discord(fake) do
      assert_enqueued_with(job: ReportDeliveryJob) do
        ReportDeliveryJob.perform_now("daily_app_report", content: "Morning.", idempotency_key: "daily:1")
      end
      assert_equal "failed", ReportDelivery.sole.status

      fake.overrides = {}
      perform_enqueued_jobs
      perform_enqueued_jobs # a stray second run
      ReportDeliveryJob.perform_now("daily_app_report", content: "Morning.", idempotency_key: "daily:1")
    end

    # Two requests reached Discord: the 502, and the one retry that posted. The
    # stray runs after it found the receipt `posted` and sent nothing.
    assert_equal 2, fake.posts.size
    assert_equal [ ReportDestinations.nonce_for("daily:1") ], fake.posts.map { |p| p[:body]["nonce"] }.uniq
    assert_equal "posted", ReportDelivery.sole.status
  end

  test "[unit] a not-configured destination is recorded, not retried" do
    with_fake_discord(fake_discord) do
      assert_no_enqueued_jobs(only: ReportDeliveryJob) do
        ReportDeliveryJob.perform_now("daily_app_report", content: "Morning.", idempotency_key: "daily:2")
      end
    end
    assert_equal "not_configured", ReportDelivery.sole.status
  end

  test "[unit] a CTO report whose soul bot was refused retries on the shared bot only, and posts once" do
    ReportDestination.create!(report_key: "cto_report:turf_monster", discord_channel: channel!)
    fake = fake_discord
    shared_down = true
    transport = lambda do |method, url, headers, body|
      if method == :post && (headers["Authorization"] == "Bot turf-soul-secret" || shared_down)
        fake.requests << { method: method, auth: headers["Authorization"] }
        status = headers["Authorization"] == "Bot turf-soul-secret" ? 403 : 502
        next [ status, JSON.generate("message" => "no") ]
      end
      fake.call(method, url, headers, body)
    end

    with_fake_discord(fake) do
      AgentMessages::DiscordBot.transport = transport
      with_env("DISCORD_BOT_TOKEN_TURF_MONSTER", "turf-soul-secret") do
        assert_enqueued_with(job: ReportDeliveryJob) do
          ReportDeliveryJob.perform_now("cto_report:turf_monster", content: "Turf.", idempotency_key: "cto:1")
        end
        assert_equal "failed", ReportDelivery.sole.status

        shared_down = false
        perform_enqueued_jobs
        perform_enqueued_jobs
      end
    end

    # The soul's bot once (403), the shared bot's 502, the shared retry that posted.
    assert_equal [ "Bot turf-soul-secret", "Bot test-token", "Bot test-token" ], fake.posts.map { |p| p[:auth] }
    assert_equal [ "posted", "shared_bot" ], [ ReportDelivery.sole.status, ReportDelivery.sole.posted_via ]
  end
end
